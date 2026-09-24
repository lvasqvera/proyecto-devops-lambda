# Accesos humanos a las tablas de DynamoDB.
#
# Vive en un state propio y no en ../: IAM es global, mientras que el stack
# principal se aplica una vez por workspace y por región. Declarar un grupo
# global ahí lo haría chocar consigo mismo entre test y prod.
#
# La regla que implementa: en test se prueba escribiendo, en producción no se
# escribe a mano. Nunca.

terraform {
  backend "s3" {
    bucket       = "s3h-terraform-backend-2026"
    key          = "iam/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "actual" {}

locals {
  cuenta = data.aws_caller_identity.actual.account_id

  tabla_test = "arn:aws:dynamodb:us-east-2:${local.cuenta}:table/TablaContactosForm-test"
  tabla_prod = "arn:aws:dynamodb:us-east-1:${local.cuenta}:table/TablaContactosForm-prod"

  # Describe* y List* van con comodín a propósito: en DynamoDB ninguna de esas
  # acciones muta nada, y los paneles de NoSQL Workbench y de la consola llaman
  # a media docena de ellas (TTL, backups, tags, réplicas, insights). Listarlas
  # una por una sería ir agregándolas a medida que aparecen los errores.
  lectura = [
    "dynamodb:GetItem",
    "dynamodb:BatchGetItem",
    "dynamodb:Query",
    "dynamodb:Scan",
    "dynamodb:PartiQLSelect",
    "dynamodb:Describe*",
    "dynamodb:List*",
  ]

  escritura = [
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:DeleteItem",
    "dynamodb:BatchWriteItem",
    "dynamodb:PartiQLInsert",
    "dynamodb:PartiQLUpdate",
    "dynamodb:PartiQLDelete",
  ]
}

resource "aws_iam_group" "desarrolladores" {
  name = "desarrolladores"
}

data "aws_iam_policy_document" "acceso_datos" {
  # ListTables no admite permisos por recurso: es una llamada de cuenta, no de
  # tabla. NoSQL Workbench y la consola la necesitan para poblar el árbol.
  # Devuelve nombres, nunca contenido.
  statement {
    sid    = "ListarTablasParaLosClientes"
    effect = "Allow"
    actions = [
      "dynamodb:ListTables",
      "dynamodb:DescribeLimits",
      "dynamodb:DescribeEndpoints",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "TestLecturaYEscritura"
    effect    = "Allow"
    actions   = concat(local.lectura, local.escritura)
    resources = [local.tabla_test, "${local.tabla_test}/index/*"]
  }

  statement {
    sid       = "ProdSoloLectura"
    effect    = "Allow"
    actions   = local.lectura
    resources = [local.tabla_prod, "${local.tabla_prod}/index/*"]
  }

  # El control de verdad. No alcanza con "no conceder" la escritura: un Deny
  # explícito gana sobre cualquier Allow, así que sigue vigente aunque después
  # se le adjunte al grupo o al usuario una política más amplia.
  statement {
    sid       = "NuncaEscribirEnProduccion"
    effect    = "Deny"
    actions   = local.escritura
    resources = [local.tabla_prod, "${local.tabla_prod}/index/*"]
  }
}

resource "aws_iam_policy" "acceso_datos" {
  name        = "DynamoDBDesarrolladores"
  description = "Lectura y escritura en la tabla de test, solo lectura en la de produccion"
  policy      = data.aws_iam_policy_document.acceso_datos.json
}

resource "aws_iam_group_policy_attachment" "acceso_datos" {
  group      = aws_iam_group.desarrolladores.name
  policy_arn = aws_iam_policy.acceso_datos.arn
}

resource "aws_iam_user" "desarrollador_datos" {
  name = "desarrollador-datos"
}

resource "aws_iam_user_group_membership" "desarrollador_datos" {
  user   = aws_iam_user.desarrollador_datos.name
  groups = [aws_iam_group.desarrolladores.name]
}

# Para NoSQL Workbench, DBeaver y la CLI.
resource "aws_iam_access_key" "desarrollador_datos" {
  user = aws_iam_user.desarrollador_datos.name
}

# Para la consola de AWS. El usuario cambia la contraseña en el primer ingreso.
resource "aws_iam_user_login_profile" "desarrollador_datos" {
  user                    = aws_iam_user.desarrollador_datos.name
  password_length         = 20
  password_reset_required = true
}

resource "aws_iam_group_policy_attachment" "cambiar_password" {
  group      = aws_iam_group.desarrolladores.name
  policy_arn = "arn:aws:iam::aws:policy/IAMUserChangePassword"
}

output "usuario" {
  value = aws_iam_user.desarrollador_datos.name
}

output "consola_url" {
  value = "https://${local.cuenta}.signin.aws.amazon.com/console"
}

output "access_key_id" {
  value = aws_iam_access_key.desarrollador_datos.id
}

output "secret_access_key" {
  value     = aws_iam_access_key.desarrollador_datos.secret
  sensitive = true
}

output "password_inicial" {
  value     = aws_iam_user_login_profile.desarrollador_datos.password
  sensitive = true
}
