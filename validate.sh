#!/bin/bash
# ================================================================================
# File: validate.sh
#
# Purpose:
#   Smoke-tests all eight GCP Serverless MCP endpoints. Authenticates as the
#   proxy service account, acquires an OIDC id_token, and calls each route,
#   checking for HTTP 200.
# ================================================================================

set -euo pipefail

# ================================================================================
# Read deployment outputs
# ================================================================================

echo "NOTE: Reading deployment outputs..."

cd 01-functions
FUNCTION_URL=$(terraform output -raw function_url)
SOURCE_BUCKET=$(terraform output -raw source_bucket_name)
cd ..

echo "NOTE: Function URL: ${FUNCTION_URL}"

# ================================================================================
# Acquire OIDC token via proxy SA key
# gcloud handles the JWT signing and exchange — no manual JWT needed here.
# ================================================================================

echo "NOTE: Acquiring OIDC token..."

# Save active account so gcloud state is restored on exit regardless of outcome.
_PREV_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
_restore_account() {
    if [[ -n "${_PREV_ACCOUNT:-}" ]]; then
        gcloud config set account "$_PREV_ACCOUNT" --quiet 2>/dev/null || true
    fi
}
trap _restore_account EXIT

gcloud auth activate-service-account \
    --key-file=02-proxy/proxy-sa-key.json \
    --quiet

# --audiences must match the Cloud Run service URL for the token to be accepted.
TOKEN=$(gcloud auth print-identity-token \
    --audiences="$FUNCTION_URL" \
    2>/dev/null)

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: Failed to acquire OIDC token."
    exit 1
fi

echo "NOTE: Token acquired."

# ================================================================================
# Helper: call one endpoint and check for HTTP 200
# ================================================================================

call_api() {
    local method="$1" route="$2" body="${3:-}"
    local tmp_file http_code response

    tmp_file=$(mktemp)

    if [[ "$method" == "GET" ]]; then
        http_code=$(curl -s -w "%{http_code}" -o "$tmp_file" \
            -X GET "${FUNCTION_URL}/${route}" \
            -H "Authorization: Bearer ${TOKEN}" \
            < /dev/null)
    else
        http_code=$(curl -s -w "%{http_code}" -o "$tmp_file" \
            -X POST "${FUNCTION_URL}/${route}" \
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
# Wait for IAM propagation
# Polls /tools until HTTP 200 — IAM bindings can take up to ~60s to propagate.
# ================================================================================

wait_for_ready() {
    local max_attempts=24 attempt=0 http_code
    echo "NOTE: Waiting for endpoint to become accessible..."
    while (( attempt < max_attempts )); do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X GET "${FUNCTION_URL}/tools" \
            -H "Authorization: Bearer ${TOKEN}" \
            < /dev/null)
        if [[ "$http_code" == "200" ]]; then
            echo "NOTE: Endpoint ready after $(( attempt * 5 ))s."
            return 0
        fi
        attempt=$(( attempt + 1 ))
        echo "NOTE: HTTP ${http_code} — retrying in 5s... (${attempt}/${max_attempts})"
        sleep 5
    done
    echo "ERROR: Endpoint not ready after $(( max_attempts * 5 ))s."
    exit 1
}

wait_for_ready

# ================================================================================
# Validate all endpoints
# ================================================================================

echo ""
echo "NOTE: Validating all endpoints..."
echo ""

call_api "GET"  "tools"
call_api "POST" "resources/compute-instances"
call_api "POST" "resources/storage-buckets"
call_api "POST" "resources/count-by-type"
call_api "POST" "resources/by-label"   '{"label_key":"env","label_value":"prod"}'
call_api "POST" "resources/static-ips"
call_api "POST" "resources/by-type"    '{"asset_type":"compute.googleapis.com/Instance"}'
call_api "POST" "resources/by-region"  '{"region":"us-central1"}'
call_api "POST" "resources/describe"        '{"resource_name":"serverless-mcp-func"}'
call_api "POST" "resources/cloud-functions"
call_api "POST" "resources/bucket-objects"  "{\"bucket_name\":\"${SOURCE_BUCKET}\}"

echo ""
echo "========================================================================"
echo "  Validation complete — all 11 endpoints returned HTTP 200."
echo "========================================================================"
echo "  API: ${FUNCTION_URL}"
echo "========================================================================"
