terraform {
  backend "s3" {
    bucket         = "s3h-terraform-backend-2026" # El nombre de tu bucket nuevo
    key            = "terraform.tfstate"          # Nombre del archivo dentro del bucket
    region         = "us-east-1"                  # Tu región
    dynamodb_table = "terraform-lock"             # El nombre de la tabla DynamoDB
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region # Puedes cambiarla a tu región preferida
}

# 1. Base de Datos DynamoDB
resource "aws_dynamodb_table" "contactos" {
  name           = "TablaContactosForm-${var.environment}"
  billing_mode   = "PROVISIONED" # Modificado para garantizar Capa Gratuita
  read_capacity  = 1             # Consumo mínimo, entra en los 25 gratis
  write_capacity = 1             # Consumo mínimo, entra en los 25 gratis
  hash_key       = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

# 2. Permisos (IAM Role) para la Lambda
resource "aws_iam_role" "lambda_exec" {
  name = "lambda_role_form_${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Damos permiso a la Lambda para escribir en DynamoDB y generar Logs
resource "aws_iam_role_policy" "lambda_dynamo_policy" {
  name = "lambda_dynamo_policy"
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["dynamodb:PutItem"]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.contactos.arn
      },
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# 3. Empaquetar el código de Node.js automáticamente
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "../backend"
  output_path = "lambda_function.zip"
}

# 4. Crear la función Lambda
resource "aws_lambda_function" "api_backend" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "ContactoAPI_${var.environment}"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.contactos.name
    }
  }
}

# 5. Crear la URL pública para la Lambda (Alternativa gratis a API Gateway)
resource "aws_lambda_function_url" "api_url" {
  function_name      = aws_lambda_function.api_backend.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["*"]
    allow_methods = ["*"]
    allow_headers = ["*"]
  }
}

# 6. Mostrar la URL al terminar
output "api_endpoint" {
  value = aws_lambda_function_url.api_url.function_url
}
# 7. Crear un Bucket S3 para alojar el Frontend
resource "aws_s3_bucket" "frontend_bucket" {
  bucket = "form-devops-frontend--${var.environment}${random_id.bucket_suffix.hex}"
}

# Generar un sufijo aleatorio para que el nombre del bucket sea único
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Configurar el bucket para que funcione como sitio web
resource "aws_s3_bucket_website_configuration" "frontend_website" {
  bucket = aws_s3_bucket.frontend_bucket.id
  index_document { suffix = "index.html" }
}

# Desactivar los bloqueos de acceso público (necesario para un sitio web)
resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket                  = aws_s3_bucket.frontend_bucket.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Política para que cualquiera en internet pueda leer el HTML
resource "aws_s3_bucket_policy" "public_read" {
  bucket = aws_s3_bucket.frontend_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend_bucket.arn}/*"
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.public_access]
}

# Subir el archivo index.html al Bucket automáticamente
resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.frontend_bucket.id
  key          = "index.html"
  source       = "../frontend/index.html"
  content_type = "text/html"
}

# Mostrar la URL de la página web al terminar
output "website_url" {
  value = aws_s3_bucket_website_configuration.frontend_website.website_endpoint
}
output "api_url" {
  value = aws_api_gateway_deployment.main.invoke_url
}