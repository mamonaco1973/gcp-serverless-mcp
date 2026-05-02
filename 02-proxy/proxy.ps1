# ================================================================================
# File: proxy.ps1
#
# Purpose:
#   MCP stdio proxy for the GCP Serverless MCP API. Reads JSON-RPC 2.0 messages
#   from stdin, acquires a GCP OIDC id_token using a service account key file,
#   and forwards tool calls to the Cloud Function.
#   The AI caller sees a local MCP server — the GCP backend is transparent.
#
#   On startup the proxy calls GET /tools (authenticated) to load the tool
#   registry. Route mappings and tool schemas require no hardcoding here.
#
# Requirements:
#   PowerShell 7.1+ (pwsh) — ImportFromPem requires .NET 5+.
#
# Required environment variables:
#   MCP_SA_KEY_FILE  Path to the proxy service account JSON key file
#   MCP_API_ENDPOINT Cloud Function base URL — no trailing slash
# ================================================================================

$ErrorActionPreference = "Stop"

# ================================================================================
# Configuration
# ================================================================================

$SA_KEY_FILE  = $env:MCP_SA_KEY_FILE
$API_ENDPOINT = $env:MCP_API_ENDPOINT
$MCP_USER     = $env:USERNAME

foreach ($var in @("MCP_SA_KEY_FILE", "MCP_API_ENDPOINT")) {
    $val = [System.Environment]::GetEnvironmentVariable($var)
    if ([string]::IsNullOrEmpty($val)) {
        [Console]::Error.WriteLine("ERROR: $var is required")
        exit 1
    }
}

# ================================================================================
# Token management
# GCP OIDC flow: self-signed JWT → exchange at Google token endpoint → id_token.
# The id_token audience equals the function URL; Cloud Run validates it before
# the function code runs.
# ================================================================================

$script:TOKEN        = ""
$script:TOKEN_EXPIRY = [DateTimeOffset]::UtcNow

function ConvertTo-Base64Url {
    param([string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertTo-Base64UrlBytes {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Acquire-Token {
    $keyJson = Get-Content $SA_KEY_FILE -Raw | ConvertFrom-Json
    $saEmail = $keyJson.client_email
    $privKey = $keyJson.private_key

    # Load RSA private key — ImportFromPem requires PowerShell 7.1+ (.NET 5+).
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($privKey)

    $now     = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $exp     = $now + 3600
    $header  = ConvertTo-Base64Url '{"alg":"RS256","typ":"JWT"}'
    $payload = ConvertTo-Base64Url (
        "{`"iss`":`"$saEmail`",`"sub`":`"$saEmail`"," +
        "`"aud`":`"https://oauth2.googleapis.com/token`"," +
        "`"iat`":$now,`"exp`":$exp," +
        "`"target_audience`":`"$API_ENDPOINT`"}"
    )

    $signingInput = "$header.$payload"
    $sigBytes     = [Text.Encoding]::UTF8.GetBytes($signingInput)
    $sigRaw       = $rsa.SignData(
        $sigBytes,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $sig       = ConvertTo-Base64UrlBytes $sigRaw
    $assertion = "$signingInput.$sig"

    $body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=$assertion"
    $resp = Invoke-WebRequest `
        -Uri "https://oauth2.googleapis.com/token" `
        -Method Post `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body `
        -UseBasicParsing

    $data = $resp.Content | ConvertFrom-Json
    if (-not $data.id_token) {
        [Console]::Error.WriteLine("ERROR: Token acquisition failed: $($data.error_description)")
        exit 1
    }
    $script:TOKEN = $data.id_token
    # id_tokens last ~1 hour; refresh 60 seconds before expiry.
    $script:TOKEN_EXPIRY = [DateTimeOffset]::UtcNow.AddSeconds(3600 - 60)
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
        serverInfo      = [ordered]@{ name = "gcp-resource-mcp"; version = "1.0.0" }
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

[Console]::Error.WriteLine("NOTE: GCP Resource MCP proxy started.")
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
        "initialize"                { if ($null -ne $id) { Handle-Initialize -Id $id } }
        "notifications/initialized" { }
        "tools/list"                { if ($null -ne $id) { Handle-ToolsList -Id $id } }
        "tools/call"                { if ($null -ne $id) { Handle-ToolsCall -Id $id -Params $params } }
        default {
            if ($null -ne $id) {
                Send-Error -Id $id -Code -32601 -Message "Method not found: $method"
            }
        }
    }
}

[Console]::Error.WriteLine("NOTE: MCP proxy exiting.")
