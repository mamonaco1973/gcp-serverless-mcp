# Video Script — Serverless CRUD API on AWS with Lambda and DynamoDB

---

[ Screen recording of the Notes Demo web app — creating, editing, and deleting notes in the browser ]

"Do you need a secure, authenticated serverless API on AWS?"

[ Architecture diagram — highlight flow: browser → Cognito → API Gateway → Lambda → DynamoDB ]

"In this project we build a fully serverless notes API using API Gateway, Lambda, and DynamoDB — secured with Cognito and provisioned entirely with Terraform."

[ Terminal running apply.sh — Terraform output, ending with website URL ]

"Follow along and in minutes you'll have a working, authenticated API running in your own AWS account."

---

## Architecture

[ Full diagram ]

"Let's walk through the architecture before we build."

[ Highlight browser and S3 bucket ]

"The user opens a static web page — which is just an HTML file served directly from a public S3 bucket."

[ Highlight API Gateway ]

"The frontend talks to an API Gateway HTTP API which is attached to our lambdas."

[ Highlight Lambda functions ]

"Each Lambda function handles exactly one thing — POST to create, GET to list, GET by ID to retrieve, PUT to update, DELETE to delete.

[ Highlight DynamoDB ]

"The backend stores data in DynamoDB. Each note is a JSON document, and the lambdas read and write directly to it."

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

[ AWS Console — us-east-1 resources ]

"Let's look at what was deployed."

[ AWS Console — API Gateway, notes-api ]

"First is the API Gateway. This is the entry point for every API call."

[ Show Routes ]

"These are the five routes — each one wired to its own Lambda integration."

[ AWS Console — Lambda functions list ]

"We have five Lambda functions — one per operation. 
Each has its own IAM role scoped to only the DynamoDB actions it needs."

[ AWS Console — DynamoDB table, notes ]

"Next is the DynamoDB table which is the storage layer for our notes.

[ AWS Console — S3 bucket, static website ]

"Finally, a public S3 bucket hosts the static web application."

[ Browser — Notes Demo loads ]

"Open the website URL to launch the test application."

---

## Demo

[ Browser — Notes Demo, open DevTools → Network tab ]

"Open the web app — and the browser debugger so we can watch the API calls."

[ Refresh page — network calls visible ]

"When the app loads, it calls the list endpoint. No notes yet."

[ Clicking New — modal opens, typing a title, clicking Create ]

"Now let's create a new note by selecting New."

[ Show API working ]

"A POST to the API is made which returns an ID."

[ Clicking the note in the list ]

"The new note is also selected and the API loads the content."

[ Editing and clicking Save ]

"Now let's update the note and select Save."

[ Show network tab ]

"A PUT call is made — and the updated data is stored in DynamoDB."

[ Clicking Delete ]

"Now let's delete the note by selecting Delete."

[ Show network ]

"A DELETE call is made — and the note is removed."

[ Browser — empty list ]

"In this demo, we've now exercised every API endpoint."

---
