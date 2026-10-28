# Serverless MCP on GCP: Cloud Asset Inventory Tools

A **serverless MCP (Model Context Protocol) backend** that lets an AI
assistant ask about your GCP resources in plain English. One second-generation
**Cloud Function** routes ten resource tools and a tool registry, and
**Cloud Run IAM** rejects any caller without an ID token for the proxy's
service account before the code runs. A small local proxy speaks MCP over
stdio to the AI client, mints and caches the token, and forwards each call,
so the remote API looks like a local tool server.

| Piece | Where | Role |
|---|---|---|
| **proxy.sh** / **proxy.ps1** | your machine | stdio MCP server (JSON-RPC 2.0); signs a JWT with the proxy key and exchanges it for an ID token, refreshed 60 s before expiry; loads its tool list from `GET /tools` |
| **serverless-mcp-func-&lt;hex&gt;** | `us-central1`, 2nd gen | Python 3.11, 256 MB, 60 s timeout, 0 to 10 instances; entry point `serverless_mcp` routes by path |
| **serverless-mcp-func-sa** | IAM | the function's identity: `roles/cloudasset.viewer` and `roles/storage.objectViewer` on the project |
| **serverless-mcp-proxy-sa** | IAM | the proxy's identity: `roles/run.invoker` and `roles/cloudfunctions.invoker` on the function only; its key is written to `02-proxy/proxy-sa-key.json` |
| **serverless-mcp-src-&lt;hex&gt;** | Cloud Storage, `US` | the function's source zip, named by its MD5 so a code change redeploys |

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="Claude Desktop runs proxy.sh or proxy.ps1 as a local MCP server over stdio. The proxy signs a JWT with the serverless-mcp-proxy-sa key and exchanges it at Google's token endpoint for an ID token, which it caches. Cloud Run IAM checks that the caller holds run.invoker before the request reaches serverless-mcp-func, a single Python 3.11 Cloud Function that routes GET /tools and ten POST /resources/* paths. It runs as its own service account, searching Cloud Asset Inventory with cloudasset.viewer and listing bucket objects with storage.objectViewer." src="architecture-light.svg">
</picture>

Regenerate with `python3 make_diagram.py`.

- **`01-functions/`**: `functions.tf` (both service accounts, their roles,
  the proxy key, the source bucket, the function and its invoker bindings),
  `main.tf` (providers; the project comes from `credentials.json`), and the
  code in `code/main.py`. `entra.tf` and `rbac.tf` hold only comments.
- **`02-proxy/`**: the Bash and PowerShell proxies.

## How a call is authorized

1. The proxy reads `proxy-sa-key.json`, signs a JWT whose `target_audience`
   is the function URL, and posts it to `https://oauth2.googleapis.com/token`
   for an ID token.
2. Cloud Run checks the token and that `serverless-mcp-proxy-sa` holds
   `roles/run.invoker`; anything else gets `403` (`401` with no token) and
   never reaches the code.
3. The function itself does no auth check. It runs as
   `serverless-mcp-func-sa`, so it can read only what that account's two
   roles allow.

## MCP tools

Each tool takes a JSON body and returns plain text, so the AI can read it
out directly.

| Tool | Route | Input | Returns |
|---|---|---|---|
| `list_compute_instances` | `POST /resources/compute-instances` | none | VMs with machine type, zone and status |
| `list_storage_buckets` | `POST /resources/storage-buckets` | none | buckets with location and storage class |
| `count_resources_by_type` | `POST /resources/count-by-type` | none | asset types ranked by count |
| `find_resources_by_label` | `POST /resources/by-label` | `label_key`, `label_value` | resources with that label |
| `list_static_ip_addresses` | `POST /resources/static-ips` | none | reserved external addresses with region and status |
| `find_resources_by_type` | `POST /resources/by-type` | `asset_type` | resources of that type, e.g. `compute.googleapis.com/Instance` |
| `find_resources_by_region` | `POST /resources/by-region` | `region` | resources in that region or zone |
| `describe_resource` | `POST /resources/describe` | `resource_name` | the full configuration of each matching resource |
| `list_cloud_functions_detail` | `POST /resources/cloud-functions` | none | functions with runtime, memory, URL, service account and environment variables |
| `list_bucket_objects` | `POST /resources/bucket-objects` | `bucket_name` | objects with size and last-modified time |

Everything except `list_bucket_objects` queries Cloud Asset Inventory,
scoped to the project. A missing required input returns `400`. For example:

```
Resources by type (14 total):

      4  compute.googleapis.com/Firewall
      2  compute.googleapis.com/Instance
      2  storage.googleapis.com/Bucket
      2  compute.googleapis.com/Network
      1  cloudfunctions.googleapis.com/CloudFunction
      ...
```

### How the proxy configures itself

At startup the proxy calls `GET /tools` and gets `TOOL_REGISTRY`:

```json
[
  {
    "name": "list_compute_instances",
    "description": "Lists all Compute Engine VM instances in the project with name, machine type, zone, and status.",
    "inputSchema": { "type": "object", "properties": {}, "required": [] },
    "route": "/resources/compute-instances"
  }
]
```

It keeps `route` for itself and hands the AI the standard MCP fields. To add
a tool, add it to `TOOL_REGISTRY` and the route table in `main.py` and
redeploy; the proxy picks it up on its next start. Because the proxy has no
tool-specific code, it can front any backend that serves `GET /tools` in
this format.

## Prerequisites

* [A Google Cloud Account](https://console.cloud.google.com/)
* [Install gcloud CLI](https://cloud.google.com/sdk/docs/install)
* [Install Terraform](https://developer.hashicorp.com/terraform/install)
* [Install jq](https://jqlang.github.io/jq/download/)
* `bash` 4+, `curl` and `openssl` (for `proxy.sh`), or **PowerShell 7+**
  (`pwsh`) for `proxy.ps1`: it loads the key with `RSA.ImportFromPem()`,
  which Windows PowerShell 5.1 doesn't have
* An MCP client: Claude Desktop, or any host that supports stdio servers

Put a service account key in the repository root as `credentials.json`. The
account needs to create service accounts and their keys, grant project IAM
roles, and deploy Cloud Functions. If this is your first time following
along, we recommend starting with this video:
[GCP + Terraform: Easy Setup](https://youtu.be/3spJpYX4f7I).

## Deploy

```bash
git clone https://github.com/mamonaco1973/gcp-serverless-mcp.git
cd gcp-serverless-mcp
./apply.sh
```

`check_env.sh` signs in with `credentials.json` and runs `api_setup.sh`,
which enables the Cloud Asset, Cloud Functions, Cloud Run, Cloud Build,
Artifact Registry and IAM APIs. `apply.sh` then applies `01-functions`,
writes the proxy key to `02-proxy/proxy-sa-key.json` (mode 600), and writes
`02-proxy/claude_desktop_config_ps1.json` and `claude_desktop_config_sh.json`;
all three are gitignored. It ends by running `validate.sh`, which gets an ID
token as the proxy account, waits up to two minutes for the endpoint, and
calls all eleven routes:

```
NOTE: Endpoint ready after 0s.

NOTE: Validating all endpoints...

NOTE: OK  GET /tools
       list_compute_instances           /resources/compute-instances
       ...
NOTE: OK  POST /resources/bucket-objects
       ...

========================================================================
  Validation complete — all 11 endpoints returned HTTP 200.
========================================================================
```

## Try it

1. Copy the `mcpServers` block from `02-proxy/claude_desktop_config_sh.json`
   (Bash) or `claude_desktop_config_ps1.json` (PowerShell) into your Claude
   Desktop `claude_desktop_config.json`, and replace
   `REPLACE_WITH_ABSOLUTE_PATH` in both the script path and
   `MCP_SA_KEY_FILE` with where you cloned the repository.
2. Restart Claude Desktop and ask, for example, "What's running in
   us-central1?" or "Describe serverless-mcp-func."
3. Call the function without a token and Cloud Run refuses it:

   ```bash
   curl -i https://<function-url>/tools
   ```

## Teardown

```bash
./destroy.sh
```

`destroy.sh` also deletes the proxy key and the generated configs.

## Notes

- **Lab only.** The proxy key is a long-lived service account key; it's in
  the Terraform state and in `02-proxy/proxy-sa-key.json`.
- `list_cloud_functions_detail` prints every function's environment
  variables, and `describe_resource` prints full resource configurations, so
  anything stored there reaches the AI client. `storage.objectViewer` is
  granted on the whole project, so `list_bucket_objects` can list any bucket
  in it.
- The proxy sends your user name in `x-mcp-user`, but this function doesn't
  log it.
- `02-proxy/claude_desktop_config_{sh,ps1}.json.tmpl` aren't used:
  `apply.sh` builds the configs with `jq`.
- `webapp.png` in this repository shows a different project (a notes demo)
  and isn't used here.
