# Terraform configuration for AWS infrastructure
# Region: ap-south-1
# Environment: dev

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

    backend "s3" {
        bucket = "iaac-genai"
        key    = "terraform/terraform.tfstate"
        region = "ap-south-1"
    }
}


provider "aws" {
    region = "ap-south-1"
    profile = "tf"
}
    

# Variables
variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "ap-south-1" # Provided in the document
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev" # Provided in the document
}

variable "lambda_role_arn" {
  description = "IAM Role ARN for Lambda functions"
  type        = string
  default     = "arn:aws:iam::851725235990:role/iaac-lambda-role" # Provided in the document
}

variable "main_lambda_runtime" {
  description = "Runtime for main Lambda function"
  type        = string
  default     = "python3.11" # Provided in the document
}

variable "main_lambda_handler" {
  description = "Handler for main Lambda function"
  type        = string
  default     = "lambda_function.lambda_handler" # Provided in the document
}

variable "main_lambda_memory" {
  description = "Memory allocation for main Lambda function"
  type        = number
  default     = 128 # Provided in the document
}

variable "main_lambda_timeout" {
  description = "Timeout for main Lambda function"
  type        = number
  default     = 20 # Provided in the document
}

variable "main_lambda_architecture" {
  description = "Architecture for main Lambda function"
  type        = string
  default     = "x86_64" # Provided in the document
}

variable "main_lambda_zip_file" {
  description = "Path to Lambda deployment package"
  type        = string
  default     = "../lambda_function.zip" # Provided in the document
}

variable "embed_lambda_runtime" {
  description = "Runtime for embed Lambda function"
  type        = string
  default     = "python3.11" # Assumed - not explicitly provided for embed lambda
}

variable "embed_lambda_handler" {
  description = "Handler for embed Lambda function"
  type        = string
  default     = "lambda_function.lambda_handler" # Assumed - not explicitly provided for embed lambda
}

variable "embed_lambda_memory" {
  description = "Memory allocation for embed Lambda function"
  type        = number
  default     = 128 # Assumed - not explicitly provided for embed lambda
}

variable "embed_lambda_timeout" {
  description = "Timeout for embed Lambda function"
  type        = number
  default     = 20 # Assumed - not explicitly provided for embed lambda
}

variable "embed_lambda_architecture" {
  description = "Architecture for embed Lambda function"
  type        = string
  default     = "x86_64" # Assumed - not explicitly provided for embed lambda
}

variable "embed_lambda_zip_file" {
  description = "Path to embed Lambda deployment package"
  type        = string
  default     = "../lambda_function.zip" # Assumed - not explicitly provided for embed lambda
}

# S3 Bucket
resource "aws_s3_bucket" "tf_rag_s3" {
  bucket        = "tf-rag-s3-${var.environment}" # Name provided in document, suffix added for uniqueness
  force_destroy = true                           # As per instructions

  tags = {
    Name        = "tf-rag-s3" # Provided in the document
    Environment = var.environment
  }
}

# DynamoDB Table
resource "aws_dynamodb_table" "tf_rag_db" {
  name         = "tf-rag-db" # Provided in the document
  billing_mode = "PAY_PER_REQUEST" # Assumed - not provided in the document
  hash_key     = "user_id"   # Provided in the document as Primary Key

  attribute {
    name = "user_id" # Provided in the document
    type = "N"       # Provided in the document (Type: Integer)
  }

  tags = {
    Name        = "tf-rag-db"
    Environment = var.environment
  }
}

# Secrets Manager Secret
resource "aws_secretsmanager_secret" "app_secret" {
  name        = "tf-rag-secret-${var.environment}" # Name assumed based on diagram
  description = "Secret for tf-rag application"    # Assumed - not provided in the document

  tags = {
    Name        = "tf-rag-secret"
    Environment = var.environment
  }
}

# Secrets Manager Secret Version
# Note: Secret value needs to be set manually or provided separately
resource "aws_secretsmanager_secret_version" "app_secret_version" {
  secret_id     = aws_secretsmanager_secret.app_secret.id
  secret_string = jsonencode({}) # Placeholder - actual secret value needs to be set manually
}

# Main Lambda Function
resource "aws_lambda_function" "tf_rag_main_lambda" {
  filename         = var.main_lambda_zip_file # Provided in the document
  function_name    = "tf-rag-main-lambda"     # Provided in the document
  role             = var.lambda_role_arn      # Provided in the document
  handler          = var.main_lambda_handler  # Provided in the document
  runtime          = var.main_lambda_runtime  # Provided in the document
  memory_size      = var.main_lambda_memory   # Provided in the document
  timeout          = var.main_lambda_timeout  # Provided in the document
  architectures    = [var.main_lambda_architecture] # Provided in the document
  source_code_hash = filebase64sha256(var.main_lambda_zip_file)

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.tf_rag_db.name
      SECRET_ARN     = aws_secretsmanager_secret.app_secret.arn
      S3_BUCKET      = aws_s3_bucket.tf_rag_s3.bucket
    }
  }

  tags = {
    Name        = "tf-rag-main-lambda"
    Environment = var.environment
  }
}

# Embed Lambda Function
resource "aws_lambda_function" "tf_rag_embed_lambda" {
  filename         = var.embed_lambda_zip_file # Assumed - not explicitly provided
  function_name    = "tf-rag-embed-lambda"     # Provided in the document
  role             = var.lambda_role_arn       # Provided in the document (same role used)
  handler          = var.embed_lambda_handler  # Assumed - not explicitly provided
  runtime          = var.embed_lambda_runtime  # Assumed - not explicitly provided
  memory_size      = var.embed_lambda_memory   # Assumed - not explicitly provided
  timeout          = var.embed_lambda_timeout  # Assumed - not explicitly provided
  architectures    = [var.embed_lambda_architecture] # Assumed - not explicitly provided
  source_code_hash = filebase64sha256(var.embed_lambda_zip_file)

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.tf_rag_s3.bucket
    }
  }

  tags = {
    Name        = "tf-rag-embed-lambda"
    Environment = var.environment
  }
}

# CloudWatch Log Group for Main Lambda
resource "aws_cloudwatch_log_group" "main_lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.tf_rag_main_lambda.function_name}"
  retention_in_days = 7 # Assumed - not provided in the document

  tags = {
    Name        = "tf-rag-main-lambda-logs"
    Environment = var.environment
  }
}

# CloudWatch Log Group for Embed Lambda
resource "aws_cloudwatch_log_group" "embed_lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.tf_rag_embed_lambda.function_name}"
  retention_in_days = 7 # Assumed - not provided in the document

  tags = {
    Name        = "tf-rag-embed-lambda-logs"
    Environment = var.environment
  }
}

# API Gateway REST API
resource "aws_api_gateway_rest_api" "tf_rag_api" {
  name        = "tf-rag-api" # Provided in the document
  description = "API Gateway for tf-rag application"

  tags = {
    Name        = "tf-rag-api"
    Environment = var.environment
  }
}

# API Gateway Resource for /query
resource "aws_api_gateway_resource" "query_resource" {
  rest_api_id = aws_api_gateway_rest_api.tf_rag_api.id
  parent_id   = aws_api_gateway_rest_api.tf_rag_api.root_resource_id
  path_part   = "query" # Provided in the document
}

# API Gateway Method for POST /query
resource "aws_api_gateway_method" "query_post" {
  rest_api_id   = aws_api_gateway_rest_api.tf_rag_api.id
  resource_id   = aws_api_gateway_resource.query_resource.id
  http_method   = "POST" # Provided in the document
  authorization = "NONE" # Assumed - not provided in the document
}

# API Gateway Integration with Lambda
resource "aws_api_gateway_integration" "query_lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.tf_rag_api.id
  resource_id             = aws_api_gateway_resource.query_resource.id
  http_method             = aws_api_gateway_method.query_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.tf_rag_main_lambda.invoke_arn
}

# Lambda Permission for API Gateway
resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tf_rag_main_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.tf_rag_api.execution_arn}/*/*"
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.tf_rag_api.id

  depends_on = [
    aws_api_gateway_integration.query_lambda_integration
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# API Gateway Stage
resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.tf_rag_api.id
  stage_name    = var.environment # Using environment variable for stage name

  tags = {
    Name        = "${var.environment}-stage"
    Environment = var.environment
  }
}

# DynamoDB trigger for embed Lambda
# Note: DynamoDB Streams and Lambda triggers need to be configured
# First, enable streams on DynamoDB table (manual configuration required)
# Then create event source mapping

# Lambda Event Source Mapping for DynamoDB
resource "aws_lambda_event_source_mapping" "dynamodb_trigger" {
  event_source_arn  = aws_dynamodb_table.tf_rag_db.stream_arn
  function_name     = aws_lambda_function.tf_rag_embed_lambda.arn
  starting_position = "LATEST" # Assumed - not provided in the document

  # Note: DynamoDB Streams must be enabled on the table for this to work
  # This requires stream_enabled = true and stream_view_type on the DynamoDB table
  depends_on = [aws_dynamodb_table.tf_rag_db]
}

# Update DynamoDB table to enable streams
resource "aws_dynamodb_table" "tf_rag_db_updated" {
  name           = "tf-rag-db"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "user_id"
  stream_enabled = true               # Required for Lambda trigger
  stream_view_type = "NEW_AND_OLD_IMAGES" # Assumed - not provided in the document

  attribute {
    name = "user_id"
    type = "N"
  }

  tags = {
    Name        = "tf-rag-db"
    Environment = var.environment
  }
}
