#AWS #Serverless #AWSLambda #DynamoDB #APIGateway #Terraform #Python #CRUD

*Build a Serverless CRUD API on AWS (API Gateway + DynamoDB)*

Deploy a fully serverless notes API on AWS using Terraform, Lambda, API Gateway, and DynamoDB. The backend runs on five Python Lambda functions — one per HTTP route — routed through an API Gateway HTTP API v2, with a static web frontend served directly from S3.

In this project we build a clean REST API with full Create, Read, Update, and Delete support — wired to a real database, deployed with a single script, and tested through a browser-based UI with no server to manage.

WHAT YOU'LL LEARN
• Deploying five Lambda functions (one per HTTP route) with Terraform
• Wiring API Gateway HTTP API v2 routes to Lambda integrations
• Provisioning DynamoDB with composite keys and least-privilege IAM roles
• Hosting a static web frontend on S3
• Injecting runtime config into HTML templates using envsubst

INFRASTRUCTURE DEPLOYED
• API Gateway HTTP API v2 (notes-api)
• Five Lambda functions (Python 3.14, one per route: create/list/get/update/delete)
• Five IAM roles with least-privilege DynamoDB policies per operation
• DynamoDB table (PAY_PER_REQUEST, PK=owner, SK=id)
• S3 bucket hosting a static web frontend

GitHub
https://github.com/mamonaco1973/aws-crud-example

README
https://github.com/mamonaco1973/aws-crud-example/blob/main/README.md

TIMESTAMPS
00:00 Introduction
00:17 Architecture
00:46 Build the Code
01:02 Build Results
01:33 Demo
