#!/bin/bash
# ================================================================================
# File: destroy.sh
#
# Purpose:
#   Tears down the Azure Resource MCP stack deployed by apply.sh.
#   Destroys the Function App, Key Vault, Entra app registrations,
#   storage, and the resource group.
# ================================================================================

set -euo pipefail

./check_env.sh

echo "NOTE: Destroying Azure infrastructure..."

cd 01-functions
terraform init -upgrade
terraform destroy -auto-approve || true
terraform destroy -auto-approve || true
cd ..

echo "NOTE: Infrastructure teardown complete."
