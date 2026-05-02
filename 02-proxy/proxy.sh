#!/bin/bash
# ================================================================================
# File: proxy.sh
#
# Purpose:
#   MCP stdio proxy for the GCP Serverless MCP API. Reads JSON-RPC 2.0 messages
#   from stdin, acquires a GCP OIDC id_token using a service account key file,
#   and forwards tool calls to the Cloud Function. The AI caller sees a local
#   MCP server — the GCP backend is transparent.
#
#   On startup the proxy calls GET /tools (authenticated) to load the tool
#   registry. Route mappings and tool schemas require no hardcoding here —
#   add a tool in main.py and redeploy; the proxy auto-discovers it.
#
# Dependencies:
#   bash 4+, curl, jq, openssl
#
# Required environment variables:
#   MCP_SA_KEY_FILE  Path to the proxy service account JSON key file
#   MCP_API_ENDPOINT Cloud Function base URL — no trailing slash
#                    (e.g. https://serverless-mcp-func-xxxx-uc.a.run.app)
# ================================================================================

set -euo pipefail

# ================================================================================
# Configuration
# ================================================================================

SA_KEY_FILE="${MCP_SA_KEY_FILE:?MCP_SA_KEY_FILE is required}"
API_ENDPOINT="${MCP_API_ENDPOINT:?MCP_API_ENDPOINT is required}"
MCP_USER="${USER:-$(whoami)}"

# ================================================================================
# Token management
# GCP OIDC flow: self-signed JWT → exchange at Google token endpoint → id_token.
# The id_token audience equals the function URL; Cloud Run validates it at the
# platform level before the function code runs.
# ================================================================================

TOKEN=""
TOKEN_EXPIRY=0

acquire_token() {
    local sa_email
    sa_email=$(jq -r '.client_email' "$SA_KEY_FILE")

    # Write private key to a temp file — openssl dgst -sign requires a path.
    local tmpkey
    tmpkey=$(mktemp /tmp/sa-key-XXXXXX.pem)
    trap 'rm -f "$tmpkey"' RETURN
    jq -r '.private_key' "$SA_KEY_FILE" > "$tmpkey"

    local now exp
    now=$(date +%s)
    exp=$(( now + 3600 ))

    # Base64url-encode the JWT header and payload.
    local header payload
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | \
        openssl base64 -e | tr -d '=\n' | tr '+/' '-_')
    payload=$(printf \
        '{"iss":"%s","sub":"%s","aud":"https://oauth2.googleapis.com/token","iat":%d,"exp":%d,"target_audience":"%s"}' \
        "$sa_email" "$sa_email" "$now" "$exp" "$API_ENDPOINT" | \
        openssl base64 -e | tr -d '=\n' | tr '+/' '-_')

    local signing_input="$header.$payload"
    local signature
    signature=$(printf '%s' "$signing_input" | \
        openssl dgst -sha256 -sign "$tmpkey" | \
        openssl base64 -e | tr -d '=\n' | tr '+/' '-_')

    local assertion="$signing_input.$signature"

    local response
    response=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
        --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --data-urlencode "assertion=${assertion}" \
        < /dev/null)

    TOKEN=$(echo "$response" | jq -r '.id_token // empty')
    if [[ -z "$TOKEN" ]]; then
        echo "ERROR: Token acquisition failed: $(echo "$response" | jq -r '.error_description // .')" >&2
        exit 1
    fi

    # id_tokens are valid for 1 hour; refresh 60 seconds before expiry.
    TOKEN_EXPIRY=$(( now + 3600 - 60 ))
}

ensure_token() {
    if [[ -z "$TOKEN" || $(date +%s) -ge $TOKEN_EXPIRY ]]; then
        acquire_token
    fi
}

# ================================================================================
# Tool registry — populated at startup from GET /tools
# ================================================================================

declare -A TOOL_ROUTES
TOOLS_JSON='[]'

# ================================================================================
# HTTP helpers
# ================================================================================

invoke_request() {
    local method="$1" url="$2" body="${3:-}"
    ensure_token

    if [[ "$method" == "GET" ]]; then
        curl -s -X GET "$url" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "x-mcp-user: ${MCP_USER}" \
            < /dev/null
    else
        curl -s -X POST "$url" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -H "x-mcp-user: ${MCP_USER}" \
            -d "${body:-{\}}" \
            < /dev/null
    fi
}

# ================================================================================
# Tool discovery
# ================================================================================

load_tool_registry() {
    local url="${API_ENDPOINT%/}/tools"
    echo "NOTE: Discovering tools from ${url} ..." >&2

    local registry
    if ! registry=$(invoke_request "GET" "$url"); then
        echo "ERROR: Tool discovery request failed." >&2
        exit 1
    fi

    if [[ -z "$registry" ]] || ! echo "$registry" | jq -e . > /dev/null 2>&1; then
        echo "ERROR: Tool discovery returned invalid JSON: ${registry}" >&2
        exit 1
    fi

    while IFS= read -r entry; do
        local name route
        name=$(echo "$entry"  | jq -r '.name')
        route=$(echo "$entry" | jq -r '.route')
        TOOL_ROUTES["$name"]="$route"
    done < <(echo "$registry" | jq -c '.[]')

    # Strip route before forwarding the tool list to the AI.
    TOOLS_JSON=$(echo "$registry" | jq -c '[.[] | {name, description, inputSchema}]')

    local count
    count=$(echo "$registry" | jq length)
    echo "NOTE: Discovered ${count} tool(s)." >&2
}

# ================================================================================
# JSON-RPC I/O helpers
# ================================================================================

send_response() {
    local id="$1" result="$2"
    jq -cn --argjson id "$id" --argjson result "$result" \
        '{"jsonrpc":"2.0","id":$id,"result":$result}'
}

send_error() {
    local id="$1" code="$2" message="$3"
    jq -cn --argjson id "$id" --argjson code "$code" --arg message "$message" \
        '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$message}}'
}

# ================================================================================
# MCP method handlers
# ================================================================================

handle_initialize() {
    local id="$1"
    local result
    result=$(jq -cn '{
        "protocolVersion": "2025-11-25",
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "gcp-resource-mcp", "version": "1.0.0"}
    }')
    send_response "$id" "$result"
}

handle_tools_list() {
    local id="$1"
    local result
    result=$(jq -cn --argjson tools "$TOOLS_JSON" '{"tools":$tools}')
    send_response "$id" "$result"
}

handle_tools_call() {
    local id="$1" params="$2"

    local tool_name
    tool_name=$(echo "$params" | jq -r '.name // empty')

    if [[ -z "$tool_name" ]]; then
        send_error "$id" -32602 "Missing required parameter: name"
        return
    fi

    local route="${TOOL_ROUTES[$tool_name]:-}"
    if [[ -z "$route" ]]; then
        send_error "$id" -32602 "Unknown tool: $tool_name"
        return
    fi

    local url="${API_ENDPOINT%/}${route}"
    local body text

    body=$(echo "$params" | jq -c '.arguments // {}')

    if ! text=$(invoke_request "POST" "$url" "$body"); then
        send_error "$id" -32603 "Tool invocation failed: curl error"
        return
    fi

    local result
    result=$(jq -cn --arg text "$text" '{"content":[{"type":"text","text":$text}]}')
    send_response "$id" "$result"
}

# ================================================================================
# Main
# ================================================================================

echo "NOTE: GCP Resource MCP proxy started." >&2
echo "NOTE: Endpoint: ${API_ENDPOINT}" >&2

load_tool_registry

while IFS= read -r line; do
    # Strip carriage returns from Windows line endings.
    line="${line//$'\r'/}"
    [[ -z "$line" ]] && continue

    if ! echo "$line" | jq -e . > /dev/null 2>&1; then
        echo "WARN: Failed to parse JSON: $line" >&2
        continue
    fi

    method=$(echo "$line" | jq -r '.method // empty')
    id_raw=$(echo "$line" | jq -c '.id // null')
    params=$(echo "$line"  | jq -c '.params // {}')

    case "$method" in
        "initialize")
            [[ "$id_raw" != "null" ]] && handle_initialize "$id_raw"
            ;;
        "notifications/initialized")
            ;;
        "tools/list")
            [[ "$id_raw" != "null" ]] && handle_tools_list "$id_raw"
            ;;
        "tools/call")
            [[ "$id_raw" != "null" ]] && handle_tools_call "$id_raw" "$params"
            ;;
        *)
            [[ "$id_raw" != "null" ]] && \
                send_error "$id_raw" -32601 "Method not found: $method"
            ;;
    esac
done

echo "NOTE: MCP proxy exiting." >&2
