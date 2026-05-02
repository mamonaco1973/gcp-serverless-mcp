#!/bin/bash
# ================================================================================
# File: destroy.sh
#
# Purpose:
#   Tears down the GCP Serverless MCP stack deployed by apply.sh.
#   Destroys the Cloud Function, service accounts, SA key, and source bucket,
#   then removes generated local files.
# ================================================================================

set -euo pipefail

./check_env.sh

echo "NOTE: Destroying GCP infrastructure..."

cd 01-functions
terraform init -upgrade
# Run twice — dependency ordering occasionally requires a second pass.
terraform destroy -auto-approve || true
cd ..

# Remove generated files that contain credentials or deployment-specific paths.
rm -f 02-proxy/proxy-sa-key.json
rm -f 02-proxy/claude_desktop_config_ps1.json
rm -f 02-proxy/claude_desktop_config_sh.json

echo "NOTE: Infrastructure teardown complete."
