# Reader on the subscription — grants the Function App's managed identity
# access to query all resources via Resource Graph.
resource "azurerm_role_assignment" "rg_reader" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_function_app_flex_consumption.serverless_mcp.identity[0].principal_id
}
