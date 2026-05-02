#!/bin/bash
# ================================================================================
# File: api_setup.sh
#
# Purpose:
#   Enables required GCP APIs for the serverless MCP stack. Called by
#   check_env.sh on every apply — safe to run multiple times (idempotent).
# ================================================================================

set -euo pipefail

PROJECT_ID=$(jq -r '.project_id' credentials.json)

echo "NOTE: Enabling required APIs for project ${PROJECT_ID}..."

gcloud services enable \
    cloudasset.googleapis.com \
    cloudfunctions.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    iam.googleapis.com \
    --project "$PROJECT_ID" \
    --quiet

echo "NOTE: APIs enabled."
