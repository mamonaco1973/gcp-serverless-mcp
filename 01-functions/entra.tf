# ================================================================================
# Entra App Registrations
# Two registrations: one defines the API audience, one is the proxy caller.
# The proxy acquires a client-credentials token scoped to the API app, which
# the Function App validates in code against Azure AD's JWKS endpoint.
# ================================================================================

# API app registration — defines the token audience for the Function App.
# No client secret needed; it only serves as the OAuth2 resource identifier.
resource "azuread_application" "serverless_mcp_api" {
  display_name = "serverless-mcp-api"
}

resource "azuread_service_principal" "serverless_mcp_api" {
  client_id = azuread_application.serverless_mcp_api.client_id
}

# Proxy app registration — the MCP proxy authenticates as this service principal.
resource "azuread_application" "serverless_mcp_proxy" {
  display_name = "serverless-mcp-proxy"
}

resource "azuread_service_principal" "serverless_mcp_proxy" {
  client_id = azuread_application.serverless_mcp_proxy.client_id
}

# Client secret for the proxy service principal.
resource "azuread_application_password" "serverless_mcp_proxy" {
  application_id = azuread_application.serverless_mcp_proxy.id
  display_name   = "serverless-mcp-proxy-secret"
  # Long expiry — rotate manually when needed.
  end_date = "2099-01-01T00:00:00Z"
}
