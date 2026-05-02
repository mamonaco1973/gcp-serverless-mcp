# ================================================================================
# File: main.py
#
# Purpose:
#   Seven Cloud Function HTTP handlers exposing an MCP-compatible resource
#   inventory API backed by GCP Cloud Asset Inventory. Authentication is
#   enforced at the platform level — Cloud Run validates the proxy's OIDC token
#   before the function runs, so no in-code auth is needed.
#
# Auth flow:
#   Proxy signs OIDC JWT with SA key → exchanges at Google token endpoint →
#   Cloud Run validates id_token → function runs → plain-text response returned
#   to AI caller.
# ================================================================================

import json
import logging
import os
from collections import Counter

import functions_framework
from google.cloud import asset_v1
from google.cloud import storage as gcs
from google.protobuf.json_format import MessageToDict

# ================================================================================
# Module-level singletons
# Instantiated once per warm instance — avoids re-initialising the client on
# every request. ADC resolves to the function's service account at runtime.
# ================================================================================

PROJECT_ID      = os.environ.get("GOOGLE_CLOUD_PROJECT", "")
_asset_client   = None
_storage_client = None


def _get_client() -> asset_v1.AssetServiceClient:
    global _asset_client
    if _asset_client is None:
        _asset_client = asset_v1.AssetServiceClient()
    return _asset_client


def _get_storage_client() -> gcs.Client:
    global _storage_client
    if _storage_client is None:
        _storage_client = gcs.Client()
    return _storage_client


# ================================================================================
# Tool registry
# Single source of truth for tool metadata and routes. The proxy fetches this
# at startup via GET /tools so no tool definitions are hardcoded in proxy.sh.
# ================================================================================

TOOL_REGISTRY = [
    {
        "name": "list_compute_instances",
        "description": (
            "Lists all Compute Engine VM instances in the project "
            "with name, machine type, zone, and status."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/resources/compute-instances",
    },
    {
        "name": "list_storage_buckets",
        "description": (
            "Lists all Cloud Storage buckets in the project "
            "with name, location, and storage class."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/resources/storage-buckets",
    },
    {
        "name": "count_resources_by_type",
        "description": (
            "Returns a ranked count of all resource types deployed "
            "in the project."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/resources/count-by-type",
    },
    {
        "name": "find_resources_by_label",
        "description": "Finds all resources matching a specific label key and value.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "label_key": {
                    "type": "string",
                    "description": "Label key to search for",
                },
                "label_value": {
                    "type": "string",
                    "description": "Label value to match",
                },
            },
            "required": ["label_key", "label_value"],
        },
        "route": "/resources/by-label",
    },
    {
        "name": "list_static_ip_addresses",
        "description": (
            "Lists all static external IP addresses in the project "
            "with name, address, region, and status."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/resources/static-ips",
    },
    {
        "name": "find_resources_by_type",
        "description": (
            "Lists all resources of a specific GCP asset type "
            "(e.g. 'compute.googleapis.com/Disk')."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "asset_type": {
                    "type": "string",
                    "description": (
                        "Full GCP asset type string, "
                        "e.g. 'compute.googleapis.com/Disk'"
                    ),
                },
            },
            "required": ["asset_type"],
        },
        "route": "/resources/by-type",
    },
    {
        "name": "find_resources_by_region",
        "description": (
            "Lists all resources deployed in a specific GCP region or zone "
            "(e.g. 'us-central1', 'us-central1-a')."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "region": {
                    "type": "string",
                    "description": (
                        "GCP region or zone name, e.g. 'us-central1'"
                    ),
                },
            },
            "required": ["region"],
        },
        "route": "/resources/by-region",
    },
    {
        "name": "describe_resource",
        "description": (
            "Returns detailed information about a specific GCP resource by "
            "name or display name, including full configuration data."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "resource_name": {
                    "type": "string",
                    "description": (
                        "Display name or partial name of the resource "
                        "to look up, e.g. 'serverless-mcp-func'"
                    ),
                },
            },
            "required": ["resource_name"],
        },
        "route": "/resources/describe",
    },
    {
        "name": "list_cloud_functions_detail",
        "description": (
            "Lists all Cloud Functions in the project with full configuration: "
            "runtime, memory, timeout, trigger URL, service account, "
            "environment variables, and instance limits."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/resources/cloud-functions",
    },
    {
        "name": "list_bucket_objects",
        "description": (
            "Lists all objects in a specific Cloud Storage bucket "
            "with name, size, and last-modified timestamp."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "bucket_name": {
                    "type": "string",
                    "description": "Name of the Cloud Storage bucket",
                },
            },
            "required": ["bucket_name"],
        },
        "route": "/resources/bucket-objects",
    },
]


# ================================================================================
# Cloud Asset Inventory helpers
# ================================================================================

def _list_assets(asset_types: list) -> list:
    """List assets using Cloud Asset Inventory ListAssets.

    Returns full resource data for each asset. Preferred over
    SearchAllResources when specific resource fields are needed (e.g.
    machineType, status) that are not surfaced in search results.

    Args:
        asset_types: GCP asset type strings such as
                     ['compute.googleapis.com/Instance'].

    Returns:
        List of Asset objects with populated resource.data fields.
    """
    client  = _get_client()
    request = asset_v1.ListAssetsRequest(
        parent       = f"projects/{PROJECT_ID}",
        asset_types  = asset_types,
        content_type = asset_v1.ContentType.RESOURCE,
    )
    return list(client.list_assets(request))


def _search_resources(query: str = "", asset_types: list = None) -> list:
    """Search resources using Cloud Asset Inventory SearchAllResources.

    Preferred over ListAssets when label or free-text filtering is needed,
    or when a uniform view across all resource types is required.

    Args:
        query:       Search query string, e.g. 'labels.env:prod'.
        asset_types: Optional list of asset type strings to restrict results.

    Returns:
        List of ResourceSearchResult objects.
    """
    client  = _get_client()
    request = asset_v1.SearchAllResourcesRequest(
        scope       = f"projects/{PROJECT_ID}",
        query       = query,
        asset_types = asset_types or [],
    )
    return list(client.search_all_resources(request))


# ================================================================================
# Request / response helpers
# ================================================================================

def _deep_convert(obj):
    """Recursively convert proto-plus collections to plain Python types.

    MapComposite and RepeatedComposite don't serialise with json.dumps —
    this walks the tree and converts them to dicts and lists.
    """
    if isinstance(obj, dict):
        return {k: _deep_convert(v) for k, v in obj.items()}
    if hasattr(obj, "items"):          # MapComposite
        return {k: _deep_convert(v) for k, v in obj.items()}
    if hasattr(obj, "__iter__") and not isinstance(obj, (str, bytes)):
        return [_deep_convert(v) for v in obj]
    return obj


def _to_dict(data) -> dict:
    """Convert resource.data to a plain Python dict.

    Proto-plus transparently unwraps google.protobuf.Struct to a MapComposite,
    which lacks the DESCRIPTOR attribute MessageToDict requires. Fall back to
    a deep recursive conversion when that happens.
    """
    try:
        return MessageToDict(data)
    except AttributeError:
        return _deep_convert(dict(data)) if data else {}


def _get_body(request) -> dict:
    """Parse JSON body from a Flask-style request, returning {} on any failure."""
    try:
        return request.get_json(silent=True) or {}
    except Exception:
        return {}


def _text_resp(body: str):
    return (body, 200, {"Content-Type": "text/plain"})


def _error_resp(exc: Exception):
    return (str(exc), 500, {"Content-Type": "text/plain"})


# ================================================================================
# Route dispatcher
# ================================================================================

@functions_framework.http
def serverless_mcp(request):
    """Main entry point — routes requests to the appropriate handler.

    Cloud Run validates the proxy's OIDC token before this function runs,
    so no auth check is performed here.

    Args:
        request: Flask-style HTTP request object.

    Returns:
        Flask-style (body, status_code, headers) tuple.
    """
    if request.method == "OPTIONS":
        headers = {
            "Access-Control-Allow-Origin":  "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization",
        }
        return ("", 204, headers)

    path = request.path.strip("/")

    routes = {
        "tools":                        tools_handler,
        "resources/compute-instances":  list_compute_instances,
        "resources/storage-buckets":    list_storage_buckets,
        "resources/count-by-type":      count_resources_by_type,
        "resources/by-label":           find_resources_by_label,
        "resources/static-ips":         list_static_ip_addresses,
        "resources/by-type":            find_resources_by_type,
        "resources/by-region":          find_resources_by_region,
        "resources/describe":           describe_resource,
        "resources/cloud-functions":    list_cloud_functions_detail,
        "resources/bucket-objects":     list_bucket_objects,
    }

    handler = routes.get(path)
    if handler is None:
        return ("Not Found", 404, {"Content-Type": "text/plain"})

    return handler(request)


# ================================================================================
# Handlers
# All handlers follow the same pattern: parse input → query Cloud Asset
# Inventory → format plain-text → return. Plain-text responses let the AI
# narrate results directly without parsing nested JSON.
# ================================================================================

def tools_handler(request):
    """Return the tool registry so the MCP proxy can self-configure at startup.

    The proxy calls this once on launch to learn route mappings and tool
    schemas. Adding a tool here and redeploying is sufficient — no proxy
    changes needed.

    Args:
        request: The incoming HTTP request.

    Returns:
        JSON array of tool descriptors including route, name, description,
        and inputSchema.
    """
    return (
        json.dumps(TOOL_REGISTRY),
        200,
        {"Content-Type": "application/json"},
    )


def list_compute_instances(request):
    """List all Compute Engine VM instances in the project.

    Args:
        request: The incoming HTTP request (body ignored).

    Returns:
        Plain-text summary of instances with name, machine type, zone,
        and status.
    """
    try:
        assets = _list_assets(["compute.googleapis.com/Instance"])
        lines  = [f"Compute Engine instances ({len(assets)} total):", ""]
        for asset in assets:
            data   = _to_dict(asset.resource.data)
            name   = data.get("name", asset.name.split("/")[-1])
            # machineType and zone are full resource URLs — extract the suffix.
            mt     = data.get("machineType", "unknown").split("/")[-1]
            zone   = data.get("zone", "unknown").split("/")[-1]
            status = data.get("status", "UNKNOWN")
            lines.append(
                f"  {name:<30}  {mt:<25}  {zone:<25}  {status}"
            )
        if not assets:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("list_compute_instances: %s", exc)
        return _error_resp(exc)


def list_storage_buckets(request):
    """List all Cloud Storage buckets in the project.

    Args:
        request: The incoming HTTP request (body ignored).

    Returns:
        Plain-text summary of buckets with name, location, and storage class.
    """
    try:
        assets = _list_assets(["storage.googleapis.com/Bucket"])
        lines  = [f"Cloud Storage buckets ({len(assets)} total):", ""]
        for asset in assets:
            data          = _to_dict(asset.resource.data)
            name          = data.get("id", asset.name.split("/")[-1])
            location      = data.get("location", "unknown")
            storage_class = data.get("storageClass", "STANDARD")
            lines.append(f"  {name:<50}  {location:<20}  {storage_class}")
        if not assets:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("list_storage_buckets: %s", exc)
        return _error_resp(exc)


def count_resources_by_type(request):
    """Return a ranked count of all resource types in the project.

    Args:
        request: The incoming HTTP request (body ignored).

    Returns:
        Plain-text ranked list of resource types with counts, most
        common first.
    """
    try:
        results = _search_resources()
        counts  = Counter(r.asset_type for r in results)
        total   = sum(counts.values())
        lines   = [f"Resources by type ({total} total):", ""]
        for asset_type, count in counts.most_common():
            lines.append(f"  {count:>5}  {asset_type}")
        if not results:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("count_resources_by_type: %s", exc)
        return _error_resp(exc)


def find_resources_by_label(request):
    """Find all resources matching a specific label key and value.

    Args:
        request: HTTP request with JSON body containing label_key and
                 label_value.

    Returns:
        Plain-text list of matching resources with name, type, and location.
        HTTP 400 if label_key or label_value is missing.
    """
    try:
        body        = _get_body(request)
        label_key   = str(body.get("label_key",   "")).strip()
        label_value = str(body.get("label_value", "")).strip()
        if not label_key or not label_value:
            return (
                "label_key and label_value are required",
                400,
                {"Content-Type": "text/plain"},
            )
        results = _search_resources(query=f"labels.{label_key}:{label_value}")
        lines   = [
            f"Resources with label {label_key}={label_value} "
            f"({len(results)} found):", ""
        ]
        for r in results:
            name = r.display_name or r.name.split("/")[-1]
            lines.append(
                f"  {name:<40}  {r.asset_type:<55}  {r.location}"
            )
        if not results:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("find_resources_by_label: %s", exc)
        return _error_resp(exc)


def list_static_ip_addresses(request):
    """List all static external IP addresses in the project.

    Args:
        request: The incoming HTTP request (body ignored).

    Returns:
        Plain-text list of static IPs with name, address, region, and
        status.
    """
    try:
        assets   = _list_assets(["compute.googleapis.com/Address"])
        # Filter for EXTERNAL only — internal static IPs are RFC1918 and
        # less relevant from a public-exposure standpoint.
        external = [
            a for a in assets
            if _to_dict(a.resource.data).get(
                "addressType", "EXTERNAL"
            ) == "EXTERNAL"
        ]
        lines = [f"Static external IP addresses ({len(external)} total):", ""]
        for asset in external:
            data    = _to_dict(asset.resource.data)
            name    = data.get("name", asset.name.split("/")[-1])
            address = data.get("address", "(unassigned)")
            # region is a full URL for regional IPs, empty for global.
            region  = (data.get("region") or "global").split("/")[-1]
            status  = data.get("status", "UNKNOWN")
            lines.append(
                f"  {name:<30}  {address:<18}  {region:<20}  {status}"
            )
        if not external:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("list_static_ip_addresses: %s", exc)
        return _error_resp(exc)


def find_resources_by_type(request):
    """List all resources of a specific GCP asset type.

    Args:
        request: HTTP request with JSON body containing asset_type.

    Returns:
        Plain-text list of matching resources with name and location.
        HTTP 400 if asset_type is missing.
    """
    try:
        body       = _get_body(request)
        asset_type = str(body.get("asset_type", "")).strip()
        if not asset_type:
            return (
                "asset_type is required",
                400,
                {"Content-Type": "text/plain"},
            )
        results = _search_resources(asset_types=[asset_type])
        lines   = [
            f"Resources of type {asset_type} ({len(results)} found):", ""
        ]
        for r in results:
            name = r.display_name or r.name.split("/")[-1]
            lines.append(f"  {name:<50}  {r.location}")
        if not results:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("find_resources_by_type: %s", exc)
        return _error_resp(exc)


def find_resources_by_region(request):
    """List all resources deployed in a specific GCP region or zone.

    Args:
        request: HTTP request with JSON body containing region name
                 (e.g. 'us-central1', 'us-central1-a').

    Returns:
        Plain-text list of resources in that region or zone. HTTP 400 if
        region is missing.
    """
    try:
        body   = _get_body(request)
        region = str(body.get("region", "")).strip().lower()
        if not region:
            return ("region is required", 400, {"Content-Type": "text/plain"})
        all_results = _search_resources()
        # startswith handles both region ('us-central1') and zone
        # ('us-central1-a') lookups against the location field.
        results = [
            r for r in all_results
            if r.location.lower().startswith(region)
        ]
        lines = [f"Resources in {region} ({len(results)} total):", ""]
        for r in results:
            name = r.display_name or r.name.split("/")[-1]
            lines.append(
                f"  {name:<40}  {r.asset_type:<55}  {r.location}"
            )
        if not results:
            lines.append(f"  (no resources found in {region})")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("find_resources_by_region: %s", exc)
        return _error_resp(exc)


def describe_resource(request):
    """Return detailed information about a GCP resource by name.

    Searches Cloud Asset Inventory by the given name, then fetches the full
    resource configuration for each match.

    Args:
        request: HTTP request with JSON body containing resource_name.

    Returns:
        Plain-text summary with search metadata and full configuration JSON
        for each matching resource. HTTP 400 if resource_name is missing.
    """
    try:
        body          = _get_body(request)
        resource_name = str(body.get("resource_name", "")).strip()
        if not resource_name:
            return (
                "resource_name is required",
                400,
                {"Content-Type": "text/plain"},
            )

        results = _search_resources(query=resource_name)
        if not results:
            return _text_resp(
                f"No resources found matching '{resource_name}'."
            )

        lines = [
            f"Found {len(results)} resource(s) matching '{resource_name}':",
            "",
        ]

        for r in results:
            display = r.display_name or r.name.split("/")[-1]
            lines.append(f"  {'─' * 68}")
            lines.append(f"  Resource:  {display}")
            lines.append(f"  Full Name: {r.name}")
            lines.append(f"  Type:      {r.asset_type}")
            lines.append(f"  Location:  {r.location or 'global'}")
            if r.state:
                lines.append(f"  State:     {r.state}")
            lines.append(f"  Project:   {r.project}")
            if r.labels:
                labels = ", ".join(f"{k}={v}" for k, v in r.labels.items())
                lines.append(f"  Labels:    {labels}")
            if r.create_time:
                lines.append(f"  Created:   {r.create_time}")
            if r.update_time:
                lines.append(f"  Updated:   {r.update_time}")

            # Fetch full resource.data for this asset type and match by name.
            try:
                full_assets = _list_assets([r.asset_type])
                for a in full_assets:
                    if a.name == r.name:
                        data        = _to_dict(a.resource.data)
                        config_json = json.dumps(data, indent=4, default=str)
                        lines.append("")
                        lines.append("  Full Configuration:")
                        for cfg_line in config_json.splitlines():
                            lines.append(f"    {cfg_line}")
                        break
            except Exception:
                pass

            lines.append("")

        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("describe_resource: %s", exc)
        return _error_resp(exc)


def list_cloud_functions_detail(request):
    """List all Cloud Functions with full configuration detail.

    Args:
        request: The incoming HTTP request (body ignored).

    Returns:
        Plain-text summary per function: runtime, entry point, memory,
        timeout, instance limits, service account, trigger URL, and
        environment variables.
    """
    try:
        assets = _list_assets(["cloudfunctions.googleapis.com/Function"])
        lines  = [f"Cloud Functions ({len(assets)} total):", ""]

        for asset in assets:
            data           = _to_dict(asset.resource.data)
            build_config   = data.get("buildConfig")   or {}
            service_config = data.get("serviceConfig") or {}

            name        = data.get("name", asset.name).split("/")[-1]
            state       = data.get("state",       "UNKNOWN")
            runtime     = build_config.get("runtime",    "unknown")
            entry_point = build_config.get("entryPoint", "unknown")
            memory      = service_config.get("availableMemory",   "unknown")
            timeout     = service_config.get("timeoutSeconds",    "unknown")
            min_inst    = service_config.get("minInstanceCount",  0)
            max_inst    = service_config.get("maxInstanceCount",  "unlimited")
            sa          = service_config.get("serviceAccountEmail", "unknown")
            uri         = service_config.get("uri",               "unknown")
            env_vars    = service_config.get("environmentVariables") or {}
            updated     = data.get("updateTime", "unknown")

            lines.append(f"  Name:          {name}")
            lines.append(f"  State:         {state}")
            lines.append(f"  Runtime:       {runtime}")
            lines.append(f"  Entry Point:   {entry_point}")
            lines.append(f"  Memory:        {memory}")
            lines.append(f"  Timeout:       {timeout}s")
            lines.append(f"  Min Instances: {min_inst}")
            lines.append(f"  Max Instances: {max_inst}")
            lines.append(f"  Service SA:    {sa}")
            lines.append(f"  Trigger URL:   {uri}")
            if env_vars:
                lines.append(f"  Env Vars:")
                for k, v in env_vars.items():
                    lines.append(f"    {k} = {v}")
            lines.append(f"  Last Updated:  {updated}")
            lines.append("")

        if not assets:
            lines.append("  (none found)")

        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("list_cloud_functions_detail: %s", exc)
        return _error_resp(exc)


def list_bucket_objects(request):
    """List all objects in a Cloud Storage bucket.

    Args:
        request: HTTP request with JSON body containing bucket_name.

    Returns:
        Plain-text list of objects with name, size, and last-modified time.
        HTTP 400 if bucket_name is missing.
    """
    try:
        body        = _get_body(request)
        bucket_name = str(body.get("bucket_name", "")).strip()
        if not bucket_name:
            return (
                "bucket_name is required",
                400,
                {"Content-Type": "text/plain"},
            )

        client = _get_storage_client()
        blobs  = list(client.list_blobs(bucket_name))

        lines = [f"Objects in gs://{bucket_name} ({len(blobs)} total):", ""]
        for blob in blobs:
            size = blob.size or 0
            if size >= 1024 * 1024:
                size_str = f"{size / (1024 * 1024):.1f} MB"
            elif size >= 1024:
                size_str = f"{size / 1024:.1f} KB"
            else:
                size_str = f"{size} B"
            updated = (
                blob.updated.strftime("%Y-%m-%d %H:%M UTC")
                if blob.updated else "unknown"
            )
            lines.append(
                f"  {blob.name:<55}  {size_str:>10}  {updated}"
            )

        if not blobs:
            lines.append("  (bucket is empty)")

        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("list_bucket_objects: %s", exc)
        return _error_resp(exc)
