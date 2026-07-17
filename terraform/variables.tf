variable "aws_region" {
  description = "Región de AWS (us-east-1 o us-east-2)"
  type        = string
}

variable "environment" {
  description = "Ambiente actual (test o prod)"
  type        = string
}