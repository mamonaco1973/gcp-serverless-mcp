# ================================================================================
# File: proxy.ps1
#
# Purpose:
#   MCP stdio proxy for the Azure Cost Management serverless API. Reads JSON-RPC
#   2.0 messages from stdin, acquires a Bearer token from Azure AD using the
#   client-credentials flow, and forwards tool calls to the Function App.
#   The AI caller sees a local MCP server — the Azure backend is transparent.
#
#   On startup the proxy calls GET /tools (authenticated) to load the tool
#   registry. Route mappings and tool schemas require no hardcoding here.
#
# Required environment variables:
#   MCP_CLIENT_ID      Proxy service principal client ID
#   MCP_CLIENT_SECRET  Proxy service principal client secret
#   MCP_TENANT_ID      Azure AD tenant ID
#   MCP_API_CLIENT_ID  API app registration client ID (token scope)
#   MCP_API_ENDPOINT   Function App base URL (no trailing slash)
# ================================================================================

$ErrorActionPreference = "Stop"

# ================================================================================
# Configuration
# ================================================================================

$CLIENT_ID     = $env:MCP_CLIENT_ID
$CLIENT_SECRET = $env:MCP_CLIENT_SECRET
$TENANT_ID     = $env:MCP_TENANT_ID
$API_CLIENT_ID = $env:MCP_API_CLIENT_ID
$API_ENDPOINT  = $env:MCP_API_ENDPOINT
$MCP_USER      = $env:USERNAME

foreach ($var in @("MCP_CLIENT_ID","MCP_CLIENT_SECRET","MCP_TENANT_ID","MCP_API_CLIENT_ID","MCP_API_ENDPOINT")) {
    if (-not (Get-Variable -Name ($var -replace "MCP_","") -ErrorAction SilentlyContinue) -or
        [string]::IsNullOrEmpty((Get-Item "env:$var" -ErrorAction SilentlyContinue).Value)) {
        [Console]::Error.WriteLine("ERROR: $var is required")
        exit 1
    }
}

# ================================================================================
# Token management
# ================================================================================

$script:TOKEN        = ""
$script:TOKEN_EXPIRY = [DateTimeOffset]::UtcNow

function Acquire-Token {
    $body = "grant_type=client_credentials" +
            "&client_id=$([Uri]::EscapeDataString($CLIENT_ID))" +
            "&client_secret=$([Uri]::EscapeDataString($CLIENT_SECRET))" +
            "&scope=$([Uri]::EscapeDataString("$API_CLIENT_ID/.default"))"

    $response = Invoke-WebRequest `
        -Uri "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" `
        -Method Post `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body `
        -UseBasicParsing

    $data = $response.Content | ConvertFrom-Json
    if (-not $data.access_token) {
        [Console]::Error.WriteLine("ERROR: Token acquisition failed: $($data.error_description)")
        exit 1
    }
    $script:TOKEN        = $data.access_token
    # Refresh 60 seconds before actual expiry.
    $script:TOKEN_EXPIRY = [DateTimeOffset]::UtcNow.AddSeconds($data.expires_in - 60)
}

function Ensure-Token {
    if ([string]::IsNullOrEmpty($script:TOKEN) -or
        [DateTimeOffset]::UtcNow -ge $script:TOKEN_EXPIRY) {
        Acquire-Token
    }
}

# ================================================================================
# Tool registry
# ================================================================================

$script:TOOL_ROUTES = @{}
$script:TOOLS_JSON  = "[]"

# ================================================================================
# HTTP helpers
# ================================================================================

function Invoke-ApiRequest {
    param(
        [string]$Method,
        [string]$Url,
        [string]$Body = "{}"
    )
    Ensure-Token
    $headers = @{
        "Authorization" = "Bearer $($script:TOKEN)"
        "x-mcp-user"    = $MCP_USER
    }
    if ($Method -eq "GET") {
        $resp = Invoke-WebRequest -Uri $Url -Method Get -Headers $headers -UseBasicParsing
    } else {
        $headers["Content-Type"] = "application/json"
        $resp = Invoke-WebRequest -Uri $Url -Method Post -Headers $headers `
                    -Body $Body -UseBasicParsing
    }
    return $resp.Content
}

# ================================================================================
# Tool discovery
# ================================================================================

function Load-ToolRegistry {
    $url = $API_ENDPOINT.TrimEnd("/") + "/tools"
    [Console]::Error.WriteLine("NOTE: Discovering tools from $url ...")

    $registry = Invoke-ApiRequest -Method "GET" -Url $url
    $parsed   = $registry | ConvertFrom-Json

    foreach ($entry in $parsed) {
        $script:TOOL_ROUTES[$entry.name] = $entry.route
    }

    # Strip route before forwarding to the AI.
    $toolsOnly = $parsed | ForEach-Object {
        [ordered]@{ name = $_.name; description = $_.description; inputSchema = $_.inputSchema }
    }
    $script:TOOLS_JSON = $toolsOnly | ConvertTo-Json -Compress -Depth 10
    if ($parsed.Count -eq 1) {
        $script:TOOLS_JSON = "[$($script:TOOLS_JSON)]"
    }

    [Console]::Error.WriteLine("NOTE: Discovered $($parsed.Count) tool(s).")
}

# ================================================================================
# JSON-RPC helpers
# ================================================================================

function Send-Response {
    param($Id, $Result)
    $msg = [ordered]@{ jsonrpc = "2.0"; id = $Id; result = $Result }
    [Console]::Out.WriteLine(($msg | ConvertTo-Json -Compress -Depth 20))
}

function Send-Error {
    param($Id, [int]$Code, [string]$Message)
    $msg = [ordered]@{
        jsonrpc = "2.0"; id = $Id
        error   = [ordered]@{ code = $Code; message = $Message }
    }
    [Console]::Out.WriteLine(($msg | ConvertTo-Json -Compress -Depth 10))
}

# ================================================================================
# MCP method handlers
# ================================================================================

function Handle-Initialize {
    param($Id)
    $result = [ordered]@{
        protocolVersion = "2025-11-25"
        capabilities    = @{ tools = @{} }
        serverInfo      = [ordered]@{ name = "azure-resource-mcp"; version = "1.0.0" }
    }
    Send-Response -Id $Id -Result $result
}

function Handle-ToolsList {
    param($Id)
    # Build response directly — ConvertTo-Json serializes PS arrays as
    # {"value":[...],"Count":N} inside hashtables, which breaks MCP clients.
    [Console]::Out.WriteLine("{`"jsonrpc`":`"2.0`",`"id`":$Id,`"result`":{`"tools`":$($script:TOOLS_JSON)}}")
}

function Handle-ToolsCall {
    param($Id, $Params)

    $toolName = $Params.name
    if (-not $toolName) {
        Send-Error -Id $Id -Code -32602 -Message "Missing required parameter: name"
        return
    }

    $route = $script:TOOL_ROUTES[$toolName]
    if (-not $route) {
        Send-Error -Id $Id -Code -32602 -Message "Unknown tool: $toolName"
        return
    }

    $url      = $API_ENDPOINT.TrimEnd("/") + $route
    $bodyJson = if ($Params.arguments) {
        $Params.arguments | ConvertTo-Json -Compress -Depth 10
    } else { "{}" }
    $text = Invoke-ApiRequest -Method "POST" -Url $url -Body $bodyJson

    # Use ConvertTo-Json only for the scalar string to get proper escaping,
    # then embed it directly — avoids the PS array hashtable serialization bug.
    $textJson = $text | ConvertTo-Json -Compress
    [Console]::Out.WriteLine("{`"jsonrpc`":`"2.0`",`"id`":$Id,`"result`":{`"content`":[{`"type`":`"text`",`"text`":$textJson}]}}")
}

# ================================================================================
# Main
# ================================================================================

[Console]::Error.WriteLine("NOTE: Azure Resource MCP proxy started.")
[Console]::Error.WriteLine("NOTE: Endpoint: $API_ENDPOINT")

Load-ToolRegistry

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.TrimEnd("`r")
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try {
        $msg = $line | ConvertFrom-Json
    } catch {
        [Console]::Error.WriteLine("WARN: Failed to parse JSON: $line")
        continue
    }

    $method = $msg.method
    $id     = $msg.id
    $params = $msg.params

    switch ($method) {
        "initialize"              { if ($null -ne $id) { Handle-Initialize -Id $id } }
        "notifications/initialized" { }
        "tools/list"              { if ($null -ne $id) { Handle-ToolsList -Id $id } }
        "tools/call"              { if ($null -ne $id) { Handle-ToolsCall -Id $id -Params $params } }
        default {
            if ($null -ne $id) {
                Send-Error -Id $id -Code -32601 -Message "Method not found: $method"
            }
        }
    }
}

[Console]::Error.WriteLine("NOTE: MCP proxy exiting.")
