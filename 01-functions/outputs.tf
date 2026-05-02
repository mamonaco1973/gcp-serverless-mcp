output "function_app_name" {
  value = azurerm_function_app_flex_consumption.serverless_mcp.name
}

output "function_app_url" {
  value = "https://${azurerm_function_app_flex_consumption.serverless_mcp.default_hostname}/api"
}

output "resource_group_name" {
  value = azurerm_resource_group.serverless_mcp.name
}

output "proxy_client_id" {
  value = azuread_application.serverless_mcp_proxy.client_id
}

output "proxy_client_secret" {
  value     = azuread_application_password.serverless_mcp_proxy.value
  sensitive = true
}

output "proxy_tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "proxy_api_client_id" {
  value = azuread_application.serverless_mcp_api.client_id
}
