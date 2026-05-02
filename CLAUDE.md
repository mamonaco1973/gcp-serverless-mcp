# CLAUDE.md — gcp-serverless-mcp

A serverless GCP Cloud Asset Inventory API designed for MCP (Model Context
Protocol) tool use. Seven Cloud Functions 2nd Gen handlers expose resource
inventory tools behind an HTTP API secured with GCP OIDC authentication. A
local MCP proxy acquires OIDC tokens from a service account key file and makes
the remote serverless backend transparent to the AI caller.

---

## What This Project Does

An AI assistant calls MCP tools that appear local but are backed by a Cloud
Function querying the GCP Cloud Asset Inventory API. Responses are plain-text
summaries suitable for direct narration — not raw JSON.

The proxy self-configures at startup by calling `GET /tools`, so route
mappings and tool schemas are defined once in `main.py` with no hardcoding
in the proxy.

**Base URL after deploy:**
```
https://{func-name}-uc.a.run.app
```

| Tool Name | Route | Operation |
|---|---|---|
| *(proxy startup)* | `GET /tools` | Tool registry for proxy self-config |
| list_compute_instances | `POST /resources/compute-instances` | All VMs with machine type, zone, status |
| list_storage_buckets | `POST /resources/storage-buckets` | All GCS buckets with location and storage class |
| count_resources_by_type | `POST /resources/count-by-type` | Ranked inventory summary |
| find_resources_by_label | `POST /resources/by-label` | Resources matching label key+value |
| list_static_ip_addresses | `POST /resources/static-ips` | All static external IPs |
| find_resources_by_type | `POST /resources/by-type` | Resources of a specific asset type |
| find_resources_by_region | `POST /resources/by-region` | Resources in a specific region or zone |

---

## Architecture

```
AI assistant (MCP client)
     │  stdio / JSON-RPC
     ▼
02-proxy/proxy.sh (or proxy.ps1)
  ├─ Signs OIDC JWT with proxy SA key file (RS256)
  ├─ Exchanges JWT at https://oauth2.googleapis.com/token → id_token
  └─ Sends Authorization: Bearer <id_token> on every request
     │  HTTPS + OIDC Bearer auth
     ▼
Cloud Function 2nd Gen (serverless-mcp-func-xxxx-uc.a.run.app)
  ├─ Cloud Run validates OIDC token at platform level (no in-code auth)
  ├─ GET  /tools                           → TOOL_REGISTRY JSON (proxy startup)
  ├─ POST /resources/compute-instances     → VM inventory
  ├─ POST /resources/storage-buckets       → GCS bucket list
  ├─ POST /resources/count-by-type         → ranked resource type summary
  ├─ POST /resources/by-label              → filter by label key+value
  ├─ POST /resources/static-ips            → static external IP inventory
  ├─ POST /resources/by-type               → resources of a specific type
  └─ POST /resources/by-region             → resources in a named region
       │
       │  Application Default Credentials (function SA)
       ▼
  Cloud Asset Inventory API
  scope: projects/{PROJECT_ID}
```

**Auth layers:**
1. Proxy signs an OIDC JWT with the proxy SA private key, exchanges it at
   the Google token endpoint, and gets an id_token with the function URL as
   audience
2. Cloud Run validates the id_token signature, audience, and expiry at the
   platform level — the function never sees unauthenticated requests
3. The function's service account queries Cloud Asset Inventory via ADC —
   no credentials in code (`roles/cloudasset.viewer` assigned at project scope)

**Why platform-level auth (not in-code):** Unlike Azure Functions FC1 which
does not support Easy Auth, Cloud Run (backing CF2) validates OIDC tokens
natively. This eliminates the JWKS-fetch-and-verify code needed in the Azure
variant.

**Why plain-text responses:** Cloud Asset Inventory returns nested proto
structs. Pre-formatted summaries let the AI narrate results without parsing.

---

## Repository Layout

```
01-functions/
  code/
    main.py          All seven handlers + Cloud Asset Inventory client
    requirements.txt functions-framework, google-cloud-asset
  main.tf            google + random + archive providers, project locals
  functions.tf       Service accounts, GCS source bucket, CF2 function,
                     Cloud Run IAM binding
  outputs.tf         function_url, proxy_sa_key_json, proxy_sa_email,
                     project_id
02-proxy/
  proxy.sh           Bash MCP stdio proxy (OIDC token, JSON-RPC dispatcher)
  proxy.ps1          PowerShell 7+ equivalent of proxy.sh
  claude_desktop_config_sh.json.tmpl   Claude Desktop config template (bash)
  claude_desktop_config_ps1.json.tmpl  Claude Desktop config template (pwsh)
api_setup.sh         Enable required GCP APIs
check_env.sh         Pre-flight: verify gcloud/terraform/jq + credentials.json
apply.sh             Full deployment + key export + config generation + validation
destroy.sh           Teardown + cleanup of generated files
validate.sh          Acquires OIDC token, calls all 8 endpoints, checks HTTP 200
credentials.json     GCP service account key (gitignored — place in repo root)
```

---

## Prerequisites

- `gcloud`, `terraform`, `jq` in PATH
- `credentials.json` (GCP service account key) in repo root
- Service account needs: Cloud Functions Admin, Cloud Run Admin,
  Cloud Build Editor, Artifact Registry Admin, IAM Admin,
  Cloud Asset Viewer, Storage Admin, Service Account Admin,
  Service Account Key Admin, Project IAM Admin

---

## Deployment

```bash
./apply.sh   # full deploy
./destroy.sh # teardown
./validate.sh # smoke test (after deploy)
```

`apply.sh` runs in sequence:
1. **`check_env.sh`** — validates tools, authenticates gcloud,
   calls `api_setup.sh` to enable APIs
2. **`01-functions` Terraform** — deploys Cloud Function, service accounts,
   IAM bindings, and source bucket
3. **Key export** — writes proxy SA key JSON to `02-proxy/proxy-sa-key.json`
4. **Config generation** — reads Terraform outputs, builds
   `02-proxy/claude_desktop_config_*.json` via `jq` (gitignored)
5. **`validate.sh`** — acquires an OIDC token and calls all 8 endpoints

---

## Terraform Resources

### 01-functions

- `google_service_account` `serverless-mcp-func-sa` — function identity
- `google_project_iam_member` — `roles/cloudasset.viewer` for function SA
- `google_service_account` `serverless-mcp-proxy-sa` — proxy identity
- `google_service_account_key` — JSON key for proxy SA (sensitive output)
- `google_storage_bucket` `serverless-mcp-src-{suffix}` — function source
- `data.archive_file` — zips `code/` directory; content hash in object name
  triggers redeploy on any source change
- `google_storage_bucket_object` — uploads zip to source bucket
- `google_cloudfunctions2_function` `serverless-mcp-func-{suffix}` —
  Python 3.11, function SA identity, 10 max instances
- `google_cloud_run_v2_service_iam_member` — `roles/run.invoker` for
  proxy SA only (restricts invocation to the proxy)

---

## Function Code

All seven handlers live in `main.py` and follow the same pattern:
1. `_list_assets(types)` or `_search_resources(query)` — queries Cloud Asset
   Inventory via `AssetServiceClient` (ADC → function SA at runtime)
2. `MessageToDict(asset.resource.data)` — converts proto Struct to Python dict
3. Format results as plain-text and return `(body, status, headers)` tuple

**Two query methods:**
- `_list_assets()` — `ListAssetsRequest` with `content_type=RESOURCE`; returns
  full resource data (machine type, status, etc.)
- `_search_resources()` — `SearchAllResourcesRequest`; supports label queries
  and free-text filtering; used for label/type/region filtering tools

**Parameterized tools:** `find_resources_by_label`, `find_resources_by_type`,
and `find_resources_by_region` read input from the POST body via `_get_body()`.

---

## MCP Proxy

`02-proxy/proxy.sh` (and `proxy.ps1` for Windows) is a stdio MCP server:
- Reads JSON-RPC 2.0 messages from stdin, writes responses to stdout
- On startup, acquires an OIDC id_token, then calls `GET /tools` to populate
  route map and tool list
- Token acquisition: self-signed RS256 JWT → POST to
  `https://oauth2.googleapis.com/token` →`id_token`
- Caches the token; re-acquires 60s before expiry
- Handles `initialize`, `tools/list`, and `tools/call` methods

Required environment variables (written into the generated config files):
```
MCP_SA_KEY_FILE   Path to proxy-sa-key.json (written by apply.sh)
MCP_API_ENDPOINT  Cloud Function URL (no trailing slash)
```

After `./apply.sh`, open `02-proxy/claude_desktop_config_ps1.json` (or `_sh`),
replace `REPLACE_WITH_ABSOLUTE_PATH` with the actual path to the repo, and
merge the `mcpServers` block into your Claude Desktop config.

**Note:** `proxy.ps1` requires PowerShell 7+ (`pwsh`) for `ImportFromPem()`
RSA key loading.
