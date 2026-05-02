#!/bin/bash
# ================================================================================
# File: check_env.sh
#
# Purpose:
#   Pre-flight validation: verifies required tools are in PATH, credentials.json
#   exists, authenticates the gcloud SA, and enables required APIs via
#   api_setup.sh.
# ================================================================================

set -euo pipefail

# ================================================================================
# Tool check
# ================================================================================

echo "NOTE: Validating required commands..."

commands=("gcloud" "terraform" "jq")
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

# ================================================================================
# Credentials check
# ================================================================================

if [[ ! -f "credentials.json" ]]; then
    echo "ERROR: credentials.json not found in $(pwd)."
    echo "       Place your GCP service account key file at credentials.json."
    exit 1
fi

PROJECT_ID=$(jq -r '.project_id'    credentials.json)
SA_EMAIL=$(jq   -r '.client_email'  credentials.json)

echo "NOTE: Project ID:       ${PROJECT_ID}"
echo "NOTE: Service account:  ${SA_EMAIL}"

# Activate the service account so gcloud commands use its identity.
gcloud auth activate-service-account \
    --key-file=credentials.json \
    --quiet

gcloud config set project "$PROJECT_ID" --quiet

echo "NOTE: gcloud authenticated as ${SA_EMAIL}."

# ================================================================================
# API enablement
# ================================================================================

./api_setup.sh
