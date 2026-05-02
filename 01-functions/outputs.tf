output "function_url" {
  value = google_cloudfunctions2_function.serverless_mcp.service_config[0].uri
}

output "proxy_sa_key_json" {
  description = "Proxy SA key JSON — written to 02-proxy/proxy-sa-key.json by apply.sh."
  value       = base64decode(google_service_account_key.proxy.private_key)
  sensitive   = true
}

output "proxy_sa_email" {
  value = google_service_account.proxy.email
}

output "project_id" {
  value = local.project_id
}

output "source_bucket_name" {
  value = google_storage_bucket.func_source.name
}
