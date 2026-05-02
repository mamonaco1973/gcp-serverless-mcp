#!/bin/bash
# ================================================================================
# File: apply.sh
#
# Purpose:
#   Orchestrates end-to-end deployment of the GCP Serverless MCP stack:
#   environment validation → Terraform (infra + function) →
#   proxy SA key export → Claude Desktop config generation → validation.
# ================================================================================

set -euo pipefail

# ================================================================================
# Environment pre-check
# ================================================================================

echo "NOTE: Running environment validation..."
./check_env.sh

# ================================================================================
# Deploy infrastructure and function
# ================================================================================

echo "NOTE: Deploying GCP infrastructure..."

cd 01-functions
terraform init -upgrade
terraform apply -auto-approve

FUNCTION_URL=$(terraform output -raw function_url)
PROJECT_ID=$(terraform output -raw project_id)
SA_EMAIL=$(terraform output -raw proxy_sa_email)

echo "NOTE: Function URL:  ${FUNCTION_URL}"
echo "NOTE: Project ID:    ${PROJECT_ID}"
echo "NOTE: Proxy SA:      ${SA_EMAIL}"

# ------------------------------------------------------------------------------
# Export proxy SA key
# Sensitive output written to a gitignored file for proxy use.
# ------------------------------------------------------------------------------

echo "NOTE: Writing proxy SA key..."
terraform output -raw proxy_sa_key_json > ../02-proxy/proxy-sa-key.json
chmod 600 ../02-proxy/proxy-sa-key.json

cd ..

# ================================================================================
# Generate Claude Desktop MCP config files
# ================================================================================

# Build config files directly from Terraform outputs — output files are
# gitignored as they contain a real service account key path.
echo "NOTE: Generating Claude Desktop config files..."

jq -n \
    --arg url "$FUNCTION_URL" \
    '{mcpServers: {"gcp-resource-mcp": {command: "pwsh",
      args: ["-File",
        "REPLACE_WITH_ABSOLUTE_PATH\\gcp-serverless-mcp\\02-proxy\\proxy.ps1"],
      env: {
        MCP_SA_KEY_FILE:
          "REPLACE_WITH_ABSOLUTE_PATH\\gcp-serverless-mcp\\02-proxy\\proxy-sa-key.json",
        MCP_API_ENDPOINT: $url}}}}' \
    > 02-proxy/claude_desktop_config_ps1.json

jq -n \
    --arg url "$FUNCTION_URL" \
    '{mcpServers: {"gcp-resource-mcp": {command: "bash",
      args: [
        "REPLACE_WITH_ABSOLUTE_PATH/gcp-serverless-mcp/02-proxy/proxy.sh"],
      env: {
        MCP_SA_KEY_FILE:
          "REPLACE_WITH_ABSOLUTE_PATH/gcp-serverless-mcp/02-proxy/proxy-sa-key.json",
        MCP_API_ENDPOINT: $url}}}}' \
    > 02-proxy/claude_desktop_config_sh.json

echo "NOTE: Config written to 02-proxy/claude_desktop_config_ps1.json"
echo "NOTE: Config written to 02-proxy/claude_desktop_config_sh.json"

# ================================================================================
# Post-deployment validation
# ================================================================================

echo "NOTE: Running post-deployment validation..."
./validate.sh
