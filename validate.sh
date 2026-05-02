#!/bin/bash
# ================================================================================
# File: validate.sh
#
# Purpose:
#   Smoke-tests all eight Azure Resource MCP endpoints. Acquires a Bearer token
#   as the proxy service principal and calls each route, checking for HTTP 200.
# ================================================================================

set -euo pipefail

# ================================================================================
# Read deployment outputs and credentials
# ================================================================================

echo "NOTE: Reading deployment outputs..."

cd 01-functions
FUNC_APP_URL=$(terraform output -raw function_app_url)
CLIENT_ID=$(terraform output -raw proxy_client_id)
CLIENT_SECRET=$(terraform output -raw proxy_client_secret)
TENANT_ID=$(terraform output -raw proxy_tenant_id)
API_CLIENT_ID=$(terraform output -raw proxy_api_client_id)
cd ..

echo "NOTE: API base URL: ${FUNC_APP_URL}"

# ================================================================================
# Acquire Bearer token
# ================================================================================

echo "NOTE: Acquiring Bearer token..."

token_json=$(curl -s -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials\
&client_id=${CLIENT_ID}\
&client_secret=${CLIENT_SECRET}\
&scope=${API_CLIENT_ID}/.default" \
  < /dev/null)

TOKEN=$(echo "$token_json" | jq -r '.access_token // empty')

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Failed to acquire token."
  echo "$token_json" | jq .
  exit 1
fi

echo "NOTE: Token acquired."

# ================================================================================
# Helper: call one endpoint and check for 200
# ================================================================================

call_api() {
  local method="$1" route="$2" body="${3:-}"
  local tmp_file http_code response

  tmp_file=$(mktemp)

  if [[ "$method" == "GET" ]]; then
    http_code=$(curl -s -w "%{http_code}" -o "$tmp_file" \
      -X GET "${FUNC_APP_URL}/${route}" \
      -H "Authorization: Bearer ${TOKEN}" \
      < /dev/null)
  else
    http_code=$(curl -s -w "%{http_code}" -o "$tmp_file" \
      -X POST "${FUNC_APP_URL}/${route}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${body:-{\}}" \
      < /dev/null)
  fi

  response=$(cat "$tmp_file")
  rm -f "$tmp_file"

  if [[ "$http_code" == "200" ]]; then
    echo "NOTE: OK  ${method} /${route}"
    echo ""
    if [[ "$route" == "tools" ]]; then
      echo "$response" | jq -r '.[] | "\(.name)\t\(.route)"' \
        | column -t -s $'\t' | sed 's/^/       /'
    else
      echo "$response" | sed 's/^/       /'
    fi
    echo ""
  else
    echo "ERROR: FAIL ${method} /${route} — HTTP ${http_code}"
    echo "  $response"
    exit 1
  fi
}

# ================================================================================
# Validate all endpoints
# ================================================================================

echo ""
echo "NOTE: Validating all endpoints..."
echo ""

call_api "GET"  "tools"
call_api "POST" "resources/virtual-machines"
call_api "POST" "resources/resource-groups"
call_api "POST" "resources/count-by-type"
call_api "POST" "resources/by-tag"   '{"tag_key":"environment","tag_value":"test"}'
call_api "POST" "resources/public-ips"
call_api "POST" "resources/by-resource-group" '{"resource_group":"serverless-mcp-rg"}'
call_api "POST" "resources/by-region" '{"region":"centralus"}'

echo ""
echo "========================================================================"
echo "  Validation complete — all 8 endpoints returned HTTP 200."
echo "========================================================================"
echo "  API: ${FUNC_APP_URL}"
echo "========================================================================"
