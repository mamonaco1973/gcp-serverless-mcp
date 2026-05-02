# ================================================================================
# Random suffix
# Appended to resource names that must be globally unique.
# ================================================================================

resource "random_id" "suffix" {
  byte_length = 4
}

# ================================================================================
# Service accounts
# Two SAs: one for the function (ADC at runtime), one for the proxy (key file).
# Separating them keeps the proxy credential out of the function's trust scope.
# ================================================================================

resource "google_service_account" "func" {
  account_id   = "serverless-mcp-func-sa"
  display_name = "Serverless MCP Function SA"
}

# Viewer on Cloud Asset Inventory — lets the function query all project assets.
resource "google_project_iam_member" "func_asset_viewer" {
  project = local.project_id
  role    = "roles/cloudasset.viewer"
  member  = "serviceAccount:${google_service_account.func.email}"
}

resource "google_service_account" "proxy" {
  account_id   = "serverless-mcp-proxy-sa"
  display_name = "Serverless MCP Proxy SA"
}

# Key written to 02-proxy/proxy-sa-key.json by apply.sh; used by the proxy to
# sign OIDC JWTs for Cloud Run invocation auth.
resource "google_service_account_key" "proxy" {
  service_account_id = google_service_account.proxy.name
}

# ================================================================================
# Function source bucket and archive
# ================================================================================

resource "google_storage_bucket" "func_source" {
  name                        = "serverless-mcp-src-${random_id.suffix.hex}"
  location                    = "US"
  force_destroy               = true
  uniform_bucket_level_access = true
}

data "archive_file" "func_source" {
  type        = "zip"
  source_dir  = "${path.module}/code"
  output_path = "${path.module}/func_source.zip"
  # Content hash in the object name triggers re-deploy on any source change.
  excludes    = ["__pycache__", "*.pyc"]
}

resource "google_storage_bucket_object" "func_source" {
  name   = "func-${data.archive_file.func_source.output_md5}.zip"
  bucket = google_storage_bucket.func_source.name
  source = data.archive_file.func_source.output_path
}

# ================================================================================
# Cloud Function (2nd Gen)
# ================================================================================

resource "google_cloudfunctions2_function" "serverless_mcp" {
  name     = "serverless-mcp-func-${random_id.suffix.hex}"
  location = "us-central1"

  build_config {
    runtime     = "python311"
    entry_point = "serverless_mcp"
    source {
      storage_source {
        bucket = google_storage_bucket.func_source.name
        object = google_storage_bucket_object.func_source.name
      }
    }
  }

  service_config {
    service_account_email = google_service_account.func.email
    min_instance_count    = 0
    max_instance_count    = 10
    available_memory      = "256M"
    timeout_seconds       = 60
    environment_variables = {
      # GOOGLE_CLOUD_PROJECT is set automatically by Cloud Run, but explicit
      # here so the value is predictable across local and deployed runs.
      GOOGLE_CLOUD_PROJECT = local.project_id
    }
  }
}

# Restrict invocation to the proxy SA only — the Cloud Run platform validates
# the OIDC token before the function runs, so no in-code auth is needed.
resource "google_cloud_run_v2_service_iam_member" "proxy_invoker" {
  project  = local.project_id
  location = google_cloudfunctions2_function.serverless_mcp.location
  name     = google_cloudfunctions2_function.serverless_mcp.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.proxy.email}"
}
