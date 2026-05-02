#!/bin/bash
# ================================================================================
# File: apply.sh
#
# Purpose:
#   Orchestrates end-to-end deployment of the Azure Resource MCP stack:
#   environment validation → Terraform (infra + Entra) →
#   function code deploy → Claude Desktop config generation → validation.
# ================================================================================

set -euo pipefail

# ================================================================================
# Environment pre-check
# ================================================================================

echo "NOTE: Running environment validation..."
./check_env.sh

# ================================================================================
# Deploy infrastructure
# ================================================================================

echo "NOTE: Deploying Azure Functions infrastructure..."

cd 01-functions
terraform init -upgrade
terraform apply -auto-approve

RESOURCE_GROUP=$(terraform output -raw resource_group_name)
FUNC_APP_NAME=$(terraform output -raw function_app_name)
FUNC_APP_URL=$(terraform output -raw function_app_url)
CLIENT_ID=$(terraform output -raw proxy_client_id)
CLIENT_SECRET=$(terraform output -raw proxy_client_secret)
TENANT_ID=$(terraform output -raw proxy_tenant_id)
API_CLIENT_ID=$(terraform output -raw proxy_api_client_id)
cd ..

echo "NOTE: Resource group: ${RESOURCE_GROUP}"
echo "NOTE: Function app:   ${FUNC_APP_NAME}"

# ================================================================================
# Deploy function code
# ================================================================================

echo "NOTE: Packaging and deploying function code..."

cd 01-functions/code
rm -f app.zip
zip -r app.zip . \
  -x "*__pycache__*" \
  -x "*.pyc" \
  -x "*.DS_Store"

az functionapp deployment source config-zip \
  --name           "$FUNC_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --src            app.zip \
  --build-remote   true

rm -f app.zip
cd ../..

# ================================================================================
# Generate Claude Desktop MCP config
# ================================================================================

# Build config files directly from Terraform outputs using jq — no Key Vault
# or envsubst needed. Output files are gitignored as they contain real secrets.
echo "NOTE: Generating Claude Desktop config files..."

jq -n \
  --arg cid  "$CLIENT_ID" \
  --arg csec "$CLIENT_SECRET" \
  --arg tid  "$TENANT_ID" \
  --arg acid "$API_CLIENT_ID" \
  --arg url  "$FUNC_APP_URL" \
  '{mcpServers: {"azure-resource-mcp": {command: "powershell",
    args: ["-File", "REPLACE_WITH_ABSOLUTE_PATH\\azure-serverless-mcp\\02-proxy\\proxy.ps1"],
    env: {MCP_CLIENT_ID: $cid, MCP_CLIENT_SECRET: $csec,
          MCP_TENANT_ID: $tid, MCP_API_CLIENT_ID: $acid, MCP_API_ENDPOINT: $url}}}}' \
  > 02-proxy/claude_desktop_config_ps1.json

jq -n \
  --arg cid  "$CLIENT_ID" \
  --arg csec "$CLIENT_SECRET" \
  --arg tid  "$TENANT_ID" \
  --arg acid "$API_CLIENT_ID" \
  --arg url  "$FUNC_APP_URL" \
  '{mcpServers: {"azure-resource-mcp": {command: "bash",
    args: ["REPLACE_WITH_ABSOLUTE_PATH/azure-serverless-mcp/02-proxy/proxy.sh"],
    env: {MCP_CLIENT_ID: $cid, MCP_CLIENT_SECRET: $csec,
          MCP_TENANT_ID: $tid, MCP_API_CLIENT_ID: $acid, MCP_API_ENDPOINT: $url}}}}' \
  > 02-proxy/claude_desktop_config_sh.json

echo "NOTE: Configs written to 02-proxy/claude_desktop_config_ps1.json"
echo "NOTE: Configs written to 02-proxy/claude_desktop_config_sh.json"

# ================================================================================
# Post-deployment validation
# ================================================================================

echo "NOTE: Running post-deployment validation..."
./validate.sh

