#GCP #MCP #CloudFunctions #Serverless #Terraform

*Build a Serverless MCP Backend using Google Cloud*

In this project we build a reusable MCP backend pattern on GCP: Cloud Function handlers behind an HTTP API secured with GCP OIDC authentication, bridged to any MCP client by a lightweight stdio proxy that acquires and caches OIDC tokens automatically.

The proxy makes the remote GCP backend look like a local tool server. The AI never knows the difference. We use Cloud Asset Inventory as the example backend — but the pattern works for any Cloud Function-backed tool set.

The proxy itself contains zero tool-specific logic. It self-configures at startup by calling a /tools discovery endpoint, so you can add or remove tools without touching the proxy at all. Point it at a different endpoint and you have a completely different tool set.

This pattern works with Claude Desktop, OpenAI Codex, Cursor, and any other MCP client that supports stdio transport.

WHAT YOU'LL LEARN
• The serverless MCP backend pattern — how to make remote Cloud Functions appear local to any AI client
• Writing a stdio MCP proxy in Bash (and PowerShell 7+) that signs OIDC JWTs with a service account key and exchanges them for id_tokens at the Google token endpoint
• Securing Cloud Functions with platform-level OIDC validation on Cloud Run — no in-code JWT validation needed (unlike the Azure variant which requires JWKS validation in code)
• Applying Application Default Credentials — the function queries Cloud Asset Inventory without credentials in code or environment variables
• Building a self-configuring /tools discovery endpoint so the proxy never needs hardcoded tool definitions
• Deploying two service accounts (function identity + proxy identity) with least-privilege IAM bindings using Terraform

INFRASTRUCTURE DEPLOYED
• Cloud Functions 2nd Gen (backed by Cloud Run) — 10 Python 3.11 handlers, scales to zero when idle (OIDC token validated at platform level before any handler runs)
• serverless-mcp-func-sa — function service account with roles/cloudasset.viewer and roles/storage.objectViewer
• serverless-mcp-proxy-sa — proxy service account with roles/run.invoker and roles/cloudfunctions.invoker; JSON key exported for proxy use
• Cloud Storage bucket for function source code
• MCP proxy (proxy.sh / proxy.ps1) — generic stdio bridge with OIDC token management, zero tool-specific logic

GitHub
https://github.com/mamonaco1973/gcp-serverless-mcp

README
https://github.com/mamonaco1973/gcp-serverless-mcp/blob/main/README.md

TIMESTAMPS
00:00 Introduction
00:16 Architecture
00:59 Build the Code
01:15 Build Results
01:52 Demo
