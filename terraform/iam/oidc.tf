# Acceso del pipeline a AWS sin llaves estáticas (OIDC).
#
# En vez de guardar un par de credenciales en los secrets de GitHub, cada job
# presenta un token efímero que GitHub firma en el momento y que declara de qué
# repositorio y rama viene. AWS lo verifica contra GitHub y entrega
# credenciales temporales.
#
# El control importante está en la política de confianza: el rol de producción
# solo se puede asumir desde master. Una rama feature con un workflow malicioso
# no puede tocar producción aunque lo intente, porque quien lo impide es AWS al
# validar el token, no el código del pipeline.

# El proveedor ya existe en la cuenta: lo creó el proyecto iachatlambda, que
# vive aquí mismo. Se referencia, no se declara, para no disputarle el recurso
# a aquel state.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  repo         = "lvasqvera/proyecto-devops-lambda"
  owner_id     = "318491865"
  repo_id      = "1302031135"
  repo_con_ids = "lvasqvera@${local.owner_id}/proyecto-devops-lambda@${local.repo_id}"

  # GitHub firma el claim `sub` con los ids numéricos incrustados cuando la
  # cuenta dueña fue renombrada alguna vez, y con el formato plano cuando no.
  # `lvasqvera` fue renombrada, pero se aceptan ambos formatos porque la
  # documentación oficial solo muestra el plano y descubrir cuál usa exige
  # decodificar un token real: dejar los dos evita un ciclo de CI a ciegas.
  ramas_test = ["develop", "feature/*", "hotfix/*"]

  subs_test = flatten([
    for rama in local.ramas_test : [
      "repo:${local.repo}:ref:refs/heads/${rama}",
      "repo:${local.repo_con_ids}:ref:refs/heads/${rama}",
    ]
  ])

  subs_prod = [
    "repo:${local.repo}:ref:refs/heads/master",
    "repo:${local.repo_con_ids}:ref:refs/heads/master",
  ]

  bucket_state = "arn:aws:s3:::s3h-terraform-backend-2026"
  tabla_lock   = "arn:aws:dynamodb:us-east-1:${local.cuenta}:table/terraform-lock"
}

data "aws_iam_policy_document" "confianza_github" {
  for_each = {
    test = local.subs_test
    prod = local.subs_prod
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "gha" {
  for_each = toset(["test", "prod"])

  name                 = "gha-deploy-${each.key}"
  description          = "Despliegue del pipeline en ${each.key}, sin llaves estaticas"
  assume_role_policy   = data.aws_iam_policy_document.confianza_github[each.key].json
  max_session_duration = 3600
}

# Permisos acotados a los recursos de cada ambiente. Se usa el comodín por
# servicio sobre un ARN concreto (no sobre "*"): si el pipeline puede borrar la
# tabla, restringirle además PutItem no protege de nada, así que el comodín
# acotado por recurso es proporcional al riesgo real.
data "aws_iam_policy_document" "gha" {
  for_each = toset(["test", "prod"])

  statement {
    sid    = "EstadoDeTerraform"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [local.bucket_state, "${local.bucket_state}/*"]
  }

  statement {
    sid       = "CandadoDeTerraform"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [local.tabla_lock]
  }

  # Llamadas de cuenta: no admiten permisos por recurso.
  statement {
    sid    = "ConsultasDeCuenta"
    effect = "Allow"
    actions = [
      "dynamodb:ListTables",
      "dynamodb:DescribeLimits",
      "lambda:ListFunctions",
      "s3:ListAllMyBuckets",
      "iam:ListRoles",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "TablaDelAmbiente"
    effect    = "Allow"
    actions   = ["dynamodb:*"]
    resources = ["arn:aws:dynamodb:*:${local.cuenta}:table/TablaContactosForm-${each.key}"]
  }

  statement {
    sid     = "LambdaDelAmbiente"
    effect  = "Allow"
    actions = ["lambda:*"]
    resources = [
      "arn:aws:lambda:*:${local.cuenta}:function:ContactoAPI_${each.key}",
      "arn:aws:lambda:*:${local.cuenta}:function:ContactoAPI_${each.key}:*",
    ]
  }

  statement {
    sid     = "BucketDelAmbiente"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::form-devops-frontend--${each.key}*",
      "arn:aws:s3:::form-devops-frontend--${each.key}*/*",
    ]
  }

  statement {
    sid    = "RolDeEjecucionDeLaLambda"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.cuenta}:role/lambda_role_form_${each.key}"]
  }

  # Entregarle el rol a la Lambda, y a nada más.
  statement {
    sid       = "EntregarElRolSoloALambda"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.cuenta}:role/lambda_role_form_${each.key}"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "gha" {
  for_each = toset(["test", "prod"])

  name        = "GitHubActionsDeploy-${each.key}"
  description = "Permisos del pipeline sobre los recursos de ${each.key}"
  policy      = data.aws_iam_policy_document.gha[each.key].json
}

resource "aws_iam_role_policy_attachment" "gha" {
  for_each = toset(["test", "prod"])

  role       = aws_iam_role.gha[each.key].name
  policy_arn = aws_iam_policy.gha[each.key].arn
}

output "rol_deploy_test" {
  description = "ARN a poner en la variable AWS_ROLE_TEST del repositorio"
  value       = aws_iam_role.gha["test"].arn
}

output "rol_deploy_prod" {
  description = "ARN a poner en la variable AWS_ROLE_PROD del repositorio"
  value       = aws_iam_role.gha["prod"].arn
}
