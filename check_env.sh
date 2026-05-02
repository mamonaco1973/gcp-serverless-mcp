#!/bin/bash
set -euo pipefail

echo "NOTE: Validating required commands..."

commands=("az" "terraform" "jq" "zip")
all_found=true

for cmd in "${commands[@]}"; do
  if command -v "$cmd" &> /dev/null; then
    echo "NOTE: $cmd found."
  else
    echo "ERROR: $cmd not found in PATH."
    all_found=false
  fi
done

[ "$all_found" = true ] || exit 1

echo "NOTE: Validating required environment variables..."

required_vars=("ARM_CLIENT_ID" "ARM_CLIENT_SECRET" "ARM_SUBSCRIPTION_ID" "ARM_TENANT_ID")
all_set=true

for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set."
    all_set=false
  else
    echo "NOTE: $var is set."
  fi
done

[ "$all_set" = true ] || exit 1

echo "NOTE: Logging in to Azure..."
az login \
  --service-principal \
  --username  "$ARM_CLIENT_ID" \
  --password  "$ARM_CLIENT_SECRET" \
  --tenant    "$ARM_TENANT_ID" \
  > /dev/null 2>&1

echo "NOTE: Azure login successful."


