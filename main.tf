provider "aws" {
}

# S3 bucket

resource "aws_s3_bucket" "bucket" {
  force_destroy = "true"
  cors_rule {
    allowed_methods = ["POST"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
  }
  lifecycle_rule {
    enabled = true

    prefix = "pending/"

    expiration {
      days = 1
    }
  }
}

resource "aws_s3_bucket_object" "object" {
  for_each = toset(["polly.jpg", "cooper.jpg", "elbert.jpg"])

  key    = each.value
  source = "${path.module}/${each.value}"
  bucket = aws_s3_bucket.bucket.bucket
  etag   = filemd5("${path.module}/${each.value}")
  lifecycle {
    ignore_changes = all
  }
}

# DDB

resource "aws_dynamodb_table" "users-table" {
  name         = "users-${random_id.id.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "Username"

  attribute {
    name = "Username"
    type = "S"
  }
}

locals {
  sample_users = [
    <<ITEM
		{
			"Username": {"S": "Polly.Mayert21"},
			"Name": {"S": "Polly Mayert"},
			"Avatar": {"S": "polly.jpg"}
		}
		ITEM
    ,
    <<ITEM
		{
			"Username": {"S": "Cooper12"},
			"Name": {"S": "Cooper Bergstrom"},
			"Avatar": {"S": "cooper.jpg"}
		}
		ITEM
    ,
    <<ITEM
		{
			"Username": {"S": "Elbert44"},
			"Name": {"S": "Elbert Legros"},
			"Avatar": {"S": "elbert.jpg"}
		}
		ITEM
  ]
}
resource "aws_dynamodb_table_item" "users" {
  for_each = toset(local.sample_users)

  table_name = aws_dynamodb_table.users-table.name
  hash_key   = aws_dynamodb_table.users-table.hash_key

  item = each.value
  lifecycle {
    ignore_changes = all
  }
}

# Lambda function

resource "random_id" "id" {
  byte_length = 8
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "/tmp/${random_id.id.hex}-lambda.zip"
  source {
    content  = file("index.js")
    filename = "index.js"
  }
  source {
    content  = file("index.html")
    filename = "index.html"
  }
}

resource "aws_lambda_function" "signer_lambda" {
  function_name = "signer-${random_id.id.hex}-function"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler = "index.handler"
  runtime = "nodejs12.x"
  role    = aws_iam_role.lambda_exec.arn
  environment {
    variables = {
      BUCKET = aws_s3_bucket.bucket.bucket
      TABLE  = aws_dynamodb_table.users-table.id
    }
  }
}

data "aws_iam_policy_document" "lambda_exec_role_policy" {
  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${aws_s3_bucket.bucket.arn}/*",
    ]
  }
  statement {
    actions = [
      "dynamodb:Scan",
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
    ]
    resources = [
      aws_dynamodb_table.users-table.arn,
    ]
  }
  statement {
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.bucket.arn,
    ]
  }
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]
  }
}

resource "aws_cloudwatch_log_group" "loggroup" {
  name              = "/aws/lambda/${aws_lambda_function.signer_lambda.function_name}"
  retention_in_days = 14
}

resource "aws_iam_role_policy" "lambda_exec_role" {
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_exec_role_policy.json
}

resource "aws_iam_role" "lambda_exec" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
	{
	  "Action": "sts:AssumeRole",
	  "Principal": {
		"Service": "lambda.amazonaws.com"
	  },
	  "Effect": "Allow"
	}
  ]
}
EOF
}

# API Gateway

resource "aws_api_gateway_rest_api" "rest_api" {
  name = "signer-${random_id.id.hex}-rest-api"
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.signer_lambda.invoke_arn
}

resource "aws_api_gateway_method" "proxy_root" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_root" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_method.proxy_root.resource_id
  http_method = aws_api_gateway_method.proxy_root.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.signer_lambda.invoke_arn
}

resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda,
    aws_api_gateway_integration.lambda_root,
  ]

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name  = "sign"
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.signer_lambda.arn
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_deployment.deployment.execution_arn}/*/*"
}

output "url" {
  value = "${aws_api_gateway_deployment.deployment.invoke_url}/"
}

output "function" {
  value = aws_lambda_function.signer_lambda.arn
}
