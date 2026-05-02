# CLAUDE.md — azure-serverless-mcp

A serverless Azure Resource Graph API designed for MCP (Model Context Protocol)
tool use. Seven Azure Functions expose resource inventory tools behind an HTTP API
secured with Entra ID Bearer tokens. A local MCP proxy acquires tokens from Azure
AD and makes the remote serverless backend transparent to the AI caller.

---

## What This Project Does

An AI assistant calls MCP tools that appear local but are backed by Azure
Functions querying the Azure Resource Graph API. Responses are plain-text
summaries suitable for direct narration — not raw JSON.

The proxy self-configures at startup by calling `GET /tools`, so route mappings
and tool schemas are defined once in `function_app.py` with no hardcoding in
the proxy.

**Base URL after deploy:**
```
https://{func-app}.azurewebsites.net/api
```

| Tool Name | Route | Operation |
|---|---|---|
| *(proxy startup)* | `GET /tools` | Tool registry for proxy self-config |
| list_virtual_machines | `POST /resources/virtual-machines` | All VMs with size and location |
| list_resource_groups | `POST /resources/resource-groups` | All RGs with location and tag count |
| count_resources_by_type | `POST /resources/count-by-type` | Ranked inventory summary |
| find_resources_by_tag | `POST /resources/by-tag` | Resources matching tag key+value |
| list_public_ip_addresses | `POST /resources/public-ips` | All public IPs |
| find_resources_by_resource_group | `POST /resources/by-resource-group` | Resources in a specific RG |
| find_resources_by_region | `POST /resources/by-region` | Resources in a specific region |

---

## Architecture

```
AI assistant (MCP client)
     │  stdio / JSON-RPC
     ▼
02-proxy/proxy.sh (or proxy.ps1)
  ├─ Acquires Bearer token from Azure AD (client_credentials flow)
  └─ Sends Authorization: Bearer <token> on every request
     │  HTTPS + Bearer auth
     ▼
Azure Functions (serverless-mcp-func-xxxx.azurewebsites.net/api)
  ├─ Validates JWT in-code against Azure AD JWKS (RS256)
  ├─ GET  /tools                        → TOOL_REGISTRY JSON (proxy startup only)
  ├─ POST /resources/virtual-machines   → VM inventory
  ├─ POST /resources/resource-groups    → RG list with tag counts
  ├─ POST /resources/count-by-type      → ranked resource type summary
  ├─ POST /resources/by-tag             → filter by tag key+value
  ├─ POST /resources/public-ips         → public IP inventory
  ├─ POST /resources/by-resource-group  → resources in a named RG
  └─ POST /resources/by-region          → resources in a named region
       │
       │  DefaultAzureCredential (Managed Identity)
       ▼
  Azure Resource Graph API
  subscriptions: [{SUBSCRIPTION_ID}]
```

**Auth layers:**
1. Proxy acquires a token for `{api_client_id}/.default` via client credentials
2. Function App validates token signature (Azure AD JWKS), audience, and expiry
3. Function App's Managed Identity queries Resource Graph — no credentials in code
   (`Reader` role assigned at subscription scope)

**Why plain-text responses:** Resource Graph returns nested JSON. Pre-formatted
summaries let the AI narrate results without parsing.

**Why in-code JWT validation:** `azurerm_function_app_flex_consumption` (FC1)
does not support the `auth_settings_v2` Easy Auth block. Token validation in
Python is equivalent security — same checks, same rejection on bad tokens.

---

## Repository Layout

```
01-functions/
  code/
    function_app.py     All seven handlers + JWT validation + Resource Graph client
    host.json           Extension bundle v4
    requirements.txt    azure-functions, azure-mgmt-resourcegraph, azure-identity,
                        PyJWT, cryptography, requests
  main.tf               azurerm + azuread + random providers, resource group
  entra.tf              Two Entra app registrations + service principal password
  functions.tf          Storage, FC1 service plan, Function App, Managed Identity
  rbac.tf               Reader on subscription for Managed Identity
  outputs.tf            function_app_name, function_app_url, resource_group_name,
                        proxy_client_id, proxy_client_secret, proxy_tenant_id,
                        proxy_api_client_id
02-proxy/
  proxy.sh              Bash MCP stdio proxy (Bearer token, JSON-RPC dispatcher)
  proxy.ps1             PowerShell equivalent of proxy.sh
  claude_desktop_config_sh.json.tmpl   Claude Desktop config template (bash)
  claude_desktop_config_ps1.json.tmpl  Claude Desktop config template (PowerShell)
check_env.sh            Pre-flight: verify az/terraform/jq/zip + ARM_ vars
apply.sh                Full deployment + config generation + validation
destroy.sh              Teardown
validate.sh             Acquires token, calls all 8 endpoints, checks HTTP 200
```

---

## Prerequisites

- `az`, `terraform`, `jq`, `zip` in PATH
- Azure subscription
- Service principal with Contributor rights for Terraform deployment
- Environment variables:
  ```
  ARM_CLIENT_ID
  ARM_CLIENT_SECRET
  ARM_SUBSCRIPTION_ID
  ARM_TENANT_ID
  ```

---

## Deployment

```bash
./apply.sh   # full deploy
./destroy.sh # teardown
./validate.sh # smoke test (after deploy)
```

`apply.sh` runs in sequence:
1. **`check_env.sh`** — validates tools and Azure credentials
2. **`01-functions` Terraform** — deploys Function App, Entra registrations,
   Managed Identity, Reader RBAC assignment
3. **Code deploy** — zips `01-functions/code/` and pushes via
   `az functionapp deployment source config-zip --build-remote true`
4. **Config generation** — reads Terraform outputs, builds
   `02-proxy/claude_desktop_config_*.json` via `jq` (gitignored)
5. **`validate.sh`** — acquires a Bearer token and calls all 8 endpoints

---

## Terraform Resources

### 01-functions

- `azurerm_resource_group` `serverless-mcp-rg`
- `azuread_application` `serverless-mcp-api` — API app registration (token audience)
- `azuread_application` `serverless-mcp-proxy` — proxy service principal
- `azuread_application_password` — client secret for proxy SP
- `azurerm_storage_account` `serverlessmcp{suffix}` — Function App code storage
- `azurerm_service_plan` `serverless-mcp-plan` — Linux FC1 (Flex Consumption)
- `azurerm_application_insights` `serverless-mcp-ai`
- `azurerm_function_app_flex_consumption` `serverless-mcp-func-{suffix}` —
  Python 3.11, SystemAssigned identity, 10 max instances
- `azurerm_role_assignment` — `Reader` on subscription for the Function App's
  managed identity principal

---

## Function Code

All seven handlers live in `function_app.py` and follow the same pattern:
1. `_validate_token(req)` — verifies Bearer JWT (signature + audience + expiry)
2. `_audit_log(req, tool)` — logs tool name and `x-mcp-user` header
3. `_rg_query(kql)` — executes KQL against Azure Resource Graph via
   `DefaultAzureCredential` (resolves to Managed Identity at runtime)
4. Format results as plain-text and return `func.HttpResponse`

**Resource Graph client:** `ResourceGraphClient(_credential)` with
`objectArray` result format — each row is a plain dict, no column-index lookup.

**Parameterized tools:** `find_resources_by_tag`, `find_resources_by_resource_group`,
and `find_resources_by_region` read input from the POST body via `_get_body(req)`.
Single quotes in user input are escaped (`''`) before interpolation into KQL.

---

## MCP Proxy

`02-proxy/proxy.sh` (and `proxy.ps1` for Windows) is a stdio MCP server:
- Reads JSON-RPC 2.0 messages from stdin, writes responses to stdout
- On startup, acquires a Bearer token, then calls `GET /tools` to populate
  route map and tool list
- Caches the token; re-acquires 60s before expiry
- Passes `params.arguments` from `tools/call` as the HTTP POST body so
  parameterized tools receive their inputs
- Handles `initialize`, `tools/list`, and `tools/call` methods

Required environment variables (written into the generated config files):
```
MCP_CLIENT_ID      Proxy service principal client ID
MCP_CLIENT_SECRET  Proxy service principal client secret
MCP_TENANT_ID      Azure AD tenant ID
MCP_API_CLIENT_ID  API app client ID (used as token scope: {id}/.default)
MCP_API_ENDPOINT   Function App URL (no trailing slash)
```

After `./apply.sh`, open `02-proxy/claude_desktop_config_ps1.json` (or `_sh`),
replace `REPLACE_WITH_ABSOLUTE_PATH` with the actual path to the proxy script,
and merge the `mcpServers` block into your Claude Desktop config.
