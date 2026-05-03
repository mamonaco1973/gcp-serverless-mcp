# Video Script — Serverless CRUD API on AWS with Lambda and DynamoDB

---

---

Do you need a clean way to run MCP backends on Google Cloud?

In this project, we implement a reusable MCP pattern using Cloud Functions and JWT based authorization.

Follow along, and in minutes you’ll have a working backend that any AI client can use to call your serverless tools on Google Cloud.

---

## Architecture

[ Full diagram ]

"Let's walk through the architecture before we build."

[ Highlight: Claude Desktop ] 
We start with the AI client — Claude Desktop — issuing MCP tool calls over standard JSON-RPC.

[ Highlight: MCP Proxy ] 

Those calls are picked up by a lightweight MCP proxy. It acts as a bridge — converting local MCP requests into HTTPS calls.

[ Highlight: Service Account Key ] 

The proxy uses a service account key to obtain an OIDC token, so every request is authenticated before it leaves the local machine.

[ Highlight: Cloud Functions ] 

On the backend, each MCP tool is implemented as a serverless Cloud Function. The function validates the OIDC token before processing the request.

[ Highlight: Cloud Asset Inventory ] 

From there, it uses its service account permissions to query Google Cloud — in this case, Cloud Asset Inventory — and returns the results.

[ Full diagram highlight ] 

So to the AI, this looks like a local MCP server.  

[ Highlight the proxy ] 

But in reality, every request is securely routed to a serverless backend in Google Cloud. That’s the core pattern.

---


## Build the Code

[ Terminal — running ./apply.sh ]

"The whole deployment is one script — apply.sh. Two phases."

[ Terminal — Phase 1: Terraform apply in 01-lambdas ]

"Phase one: Terraform provisions DynamoDB, all five Lambda functions, their IAM roles, and the API Gateway — everything wired together with least-privilege permissions."

[ Terminal — API endpoint discovery and envsubst ]

"Between phases, the script looks up the API Gateway endpoint and injects it into the HTML template using envsubst."

[ Terminal — Phase 2: Terraform apply in 02-webapp ]

"Phase two: Terraform creates the S3 bucket and uploads the generated index.html. The site is live."

[ Terminal — validate.sh running smoke tests ]

"Finally, validate.sh runs an end-to-end smoke test — creates five notes, lists them, fetches one, updates it, and deletes it."

[ Terminal — deployment complete, URLs printed ]

"API URL. Website URL. Done."

---

## Build Results

[ Show Cloud Function ] A serverless Cloud Function is deployed as the entry point for all MCP tool calls.

[ Show Code ] All requests are secured with an OIDC Bearer token on every call.

[ Show Service Account ] A dedicated service account is created for the proxy to authenticate against the API.

[ Show Proxy Config / Env ] The proxy uses this service account key to acquire and cache OIDC tokens for request authentication.

[ Show Python Code ] All tool logic is implemented in Python, with each handler querying Google Cloud services.

[ Show Tool Registry ] A central tool registry defines all available tools, which the proxy loads dynamically at startup.

[ Show Desktop JSON ] Finally, client configuration files are generated, allowing the MCP client to connect to the backend. 
---

## Demo

First, update your AI client configuration — here I’m using Claude Desktop.

On windows Powershell 7 is required, make sure the "pwsh" command is available. 

Restart the client and confirm it recognizes the serverless MCP.

Now let’s try it — show me all my cloud functions.

You’ll get a complete list acros the project.

Next, Ask for details on the mcp cloud function.

Now we get a descripton of the mcp cloud function.

Finally, ask it to interpret what this cloud function does.

Here it correctly identifies this as an AI assistant backend.
