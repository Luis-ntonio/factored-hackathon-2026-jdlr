locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "agent"
    },
    var.tags
  )

  # Hash combinado de todo el código fuente que puede afectar el contenido de
  # los 7 zips (los 7 servicios + su dependencia compartida packages/shared +
  # policies.yaml, empaquetado dentro de policy-agent/transaction-agent/
  # verification-agent). Recalcula el trigger del null_resource de build cada
  # vez que cambia cualquiera de estos archivos -- fileset()/filesha1() son
  # funciones de Terraform evaluadas en cada plan, sin necesidad de un paso
  # externo.
  #
  # BUG REAL encontrado en este checkpoint: al agregar auth-agent como 7mo
  # servicio, este `source_dirs` no se actualizó al mismo tiempo -- un fix
  # posterior en services/auth-agent/src/login.ts (normalización de tildes)
  # NO disparó un rebuild (`terraform plan` reportaba "No changes" con el
  # Lambda desplegado corriendo código viejo) porque el hash de este local
  # nunca vio ese archivo. Cualquier servicio nuevo que se agregue a futuro
  # DEBE agregarse acá en el mismo commit, no después.
  # BUG REAL adicional encontrado (2026-09-28): este hash originalmente solo
  # cubría el código FUENTE de los servicios -- nunca el propio
  # `terraform/scripts/package-lambdas.js` que los empaqueta. Un cambio en
  # la lógica de empaquetado (ej. el fix de abajo, que agrega un paso de
  # `npm run build` de transaction-agent antes de bundlear) no disparaba un
  # rebuild por sí solo. Se agrega `terraform/scripts` a la lista para que
  # cualquier cambio en el pipeline de build también cuente como motivo de
  # re-bundle, mismo criterio que el resto de esta lista.
  source_dirs = [
    "${var.repo_root}/services/conversation-agent/src",
    "${var.repo_root}/services/policy-agent/src",
    "${var.repo_root}/services/retrieval-agent/src",
    "${var.repo_root}/services/transaction-agent/src",
    "${var.repo_root}/services/verification-agent/src",
    "${var.repo_root}/services/escalation-agent/src",
    "${var.repo_root}/services/auth-agent/src",
    "${var.repo_root}/services/admin-agent/src",
    "${var.repo_root}/packages/shared/src",
    "${var.repo_root}/terraform/scripts",
  ]

  source_files = flatten([
    for dir in local.source_dirs : [
      for f in fileset(dir, "**") : "${dir}/${f}"
    ]
  ])

  sources_hash  = sha1(join("", [for f in sort(local.source_files) : filesha1(f)]))
  policies_hash = filemd5("${var.repo_root}/policies.yaml")
}

# --- Build: esbuild bundling de los 6 Lambdas (ver terraform/scripts/
# package-lambdas.js para la justificación completa de por qué esbuild en
# vez de zippear dist/+node_modules tal cual -- riesgo real de symlinks
# rotos de npm workspaces en @banking-agent/shared). Corre en cada apply
# donde cambie el código fuente relevante o policies.yaml.
resource "null_resource" "build_lambdas" {
  count = var.enable_lambda_build ? 1 : 0

  triggers = {
    sources_hash  = local.sources_hash
    policies_hash = local.policies_hash
  }

  provisioner "local-exec" {
    working_dir = var.repo_root
    command     = "node terraform/scripts/package-lambdas.js"
  }
}

data "archive_file" "conversation_agent" {
  type        = "zip"
  source_dir  = "${path.module}/build/conversation-agent"
  output_path = "${path.module}/build/conversation-agent.zip"

  depends_on = [null_resource.build_lambdas]
}

data "archive_file" "policy_agent" {
  type        = "zip"
  source_dir  = "${path.module}/build/policy-agent"
  output_path = "${path.module}/build/policy-agent.zip"

  depends_on = [null_resource.build_lambdas]
}

data "archive_file" "retrieval_agent" {
  type        = "zip"
  source_dir  = "${path.module}/build/retrieval-agent"
  output_path = "${path.module}/build/retrieval-agent.zip"

  depends_on = [null_resource.build_lambdas]
}

data "archive_file" "transaction_agent" {
  type        = "zip"
  source_dir  = "${path.module}/build/transaction-agent"
  output_path = "${path.module}/build/transaction-agent.zip"

  depends_on = [null_resource.build_lambdas]
}

data "archive_file" "verification_agent" {
  type        = "zip"
  source_dir  = "${path.module}/build/verification-agent"
  output_path = "${path.module}/build/verification-agent.zip"

  depends_on = [null_resource.build_lambdas]
}

data "archive_file" "escalation_agent" {
  type        = "zip"
  source_dir  = "${path.module}/build/escalation-agent"
  output_path = "${path.module}/build/escalation-agent.zip"

  depends_on = [null_resource.build_lambdas]
}

data "archive_file" "auth_agent" {
  type        = "zip"
  source_dir  = "${path.module}/build/auth-agent"
  output_path = "${path.module}/build/auth-agent.zip"

  depends_on = [null_resource.build_lambdas]
}

# --- IAM: trust policy común de Lambda ---
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- Bedrock IAM real (fase "Habilitar Bedrock real" -- ver README.md,
# sección "Bedrock IAM: decisión de diferir (RESUELTO)"). Consumido SOLO por
# conversation_agent/policy_agent más abajo. ---
#
# Identity de la cuenta actual -- necesaria para construir ARNs exactos de
# Bedrock/SSM sin hardcodear el account ID en ningún .tf (mismo criterio ya
# aplicado en docs/: nunca commitear el account ID literal).
data "aws_caller_identity" "current" {}

# Clave KMS administrada por AWS que cifra el parámetro SecureString del
# secreto de sesión (module.secrets, sin `key_id` custom -> default
# "alias/aws/ssm"). Necesaria para el statement kms:Decrypt de auth_agent/
# conversation_agent más abajo -- ssm:GetParameter sobre un SecureString
# SIEMPRE requiere también kms:Decrypt sobre la clave que lo cifra.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

locals {
  # ARN del inference profile cross-region (prefijo "us.") elegido en
  # module.secrets. Recurso primario al que se scopea bedrock:InvokeModel/
  # Converse -- nunca Resource = "*".
  bedrock_inference_profile_arn = "arn:aws:bedrock:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}"

  # Verificado empíricamente (test real: Lambda temporal desplegada con el
  # rol exacto de conversation_agent, invocada de punta a punta -- ver
  # README.md, sección "Bedrock IAM: decision de diferir (RESUELTO)" para el
  # detalle completo): otorgar SOLO el ARN del inference profile NO alcanza.
  # ConverseCommand contra un inference profile cross-region (prefijo "us.")
  # devuelve AccessDeniedException real:
  #   "is not authorized to perform: bedrock:InvokeModel on resource:
  #    arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6
  #    because no identity-based policy allows the bedrock:InvokeModel action"
  # -- Bedrock evalúa el permiso identity-based tambien contra el ARN del
  # foundation model subyacente (sin account ID, recurso público de AWS), no
  # solo contra el inference profile. Se agrega el ARN de foundation-model en
  # la MISMA region que bedrock_region (unica probada empiricamente) -- no se
  # agregan preventivamente us-east-2/us-west-2 (aunque el prefijo "us."
  # cubre esas regiones para el ROUTING interno de AWS) porque el principio
  # de este proyecto es minimo privilegio verificado, no maximo privilegio
  # especulativo: si en el futuro una invocacion real falla porque AWS
  # enruto a otra region, se agrega esa region especifica con la misma
  # evidencia empirica que esta.
  # Se probaron 2 invocaciones reales consecutivas (misma Lambda de prueba,
  # mismo rol, mismo modelId) contra la region bedrock_region (us-east-1):
  # la primera fue enrutada por AWS internamente a us-east-1, la segunda a
  # us-east-2 -- confirma que el enrutamiento cross-region del prefijo "us."
  # es real y no deterministico (no alcanza con el foundation-model ARN de
  # una sola region). Se agregan las 3 regiones que cubre el prefijo "us."
  # segun la documentacion de AWS (us-east-1/us-east-2/us-west-2) -- ver
  # README.md para el detalle completo de ambas invocaciones reales.
  bedrock_foundation_model_arns = [
    for region in ["us-east-1", "us-east-2", "us-west-2"] :
    "arn:aws:bedrock:${region}::foundation-model/${replace(var.bedrock_model_id, "us.", "")}"
  ]

  bedrock_resource_arns = concat(
    [local.bedrock_inference_profile_arn],
    local.bedrock_foundation_model_arns,
  )

  # ARNs de los parámetros SSM que conversation-agent/policy-agent leen en
  # runtime (BEDROCK_MODEL_ID_PARAM_NAME/BEDROCK_REGION_PARAM_NAME, ver
  # bloque `environment` de cada Lambda más abajo) -- scoping exacto a los 2
  # parámetros, no al path completo (aunque module.secrets documenta esa
  # alternativa como opción válida).
  bedrock_ssm_parameter_arns = [
    "arn:aws:ssm:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:parameter${var.bedrock_model_id_ssm_parameter_name}",
    "arn:aws:ssm:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:parameter${var.bedrock_region_ssm_parameter_name}",
  ]

  # Titan Embeddings se invoca DIRECTO por su model ID, sin inference
  # profile (a diferencia de Claude Sonnet arriba) -- verificado con una
  # invocación real contra esta cuenta antes de fijar este diseño (ver
  # plan/README: devuelve un vector de 1024 dims sin necesitar profile).
  # Recurso público de AWS (sin account ID), scoped a UNA sola región
  # (embedding_region) -- no se agregan preventivamente otras regiones
  # porque, a diferencia del inference profile "us." de Claude, Titan no
  # tiene routing cross-region: si una invocación real fallara por region
  # mismatch, se agregaría esa región específica con la misma evidencia
  # empírica que el resto de este archivo.
  embedding_foundation_model_arn = "arn:aws:bedrock:${var.embedding_region}::foundation-model/${var.embedding_model_id}"

  embedding_ssm_parameter_arns = [
    var.embedding_model_id_ssm_parameter_arn,
  ]
}

# =====================================================================
# conversation-agent -- capa Understand.
# IAM de mínimo privilegio (gap 3, Tarea 3 del checkpoint "AWS real"):
# DynamoDB Get/Put/Query sobre case_store + (fase "Habilitar Bedrock real")
# bedrock:InvokeModel/Converse scoped al inference profile elegido, y
# ssm:GetParameter scoped a los 2 parámetros de config de Bedrock.
# Deliberadamente SIN lambda:InvokeFunction sobre ningún recurso -- no
# necesita invocar otros Lambdas, y esa ausencia es justamente lo que
# garantiza que no pueda saltearse la Step Function e invocar
# retrieval-agent/transaction-agent directamente.
# =====================================================================
resource "aws_iam_role" "conversation_agent" {
  name               = "${local.name_prefix}-conversation-agent-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "conversation_agent_basic_logs" {
  role       = aws_iam_role.conversation_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "conversation_agent_dynamodb" {
  name = "${local.name_prefix}-conversation-agent-dynamodb"
  role = aws_iam_role.conversation_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
        ]
        Resource = [
          var.case_store_table_arn,
          "${var.case_store_table_arn}/index/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "conversation_agent_bedrock" {
  name = "${local.name_prefix}-conversation-agent-bedrock"
  role = aws_iam_role.conversation_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeBedrockInferenceProfile"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:Converse",
        ]
        Resource = local.bedrock_resource_arns
      }
    ]
  })
}

resource "aws_iam_role_policy" "conversation_agent_ssm" {
  name = "${local.name_prefix}-conversation-agent-ssm"
  role = aws_iam_role.conversation_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadBedrockConfigParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = local.bedrock_ssm_parameter_arns
      },
      {
        Sid      = "ReadSessionTokenSecret"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [var.session_token_secret_parameter_arn]
      },
      {
        Sid      = "DecryptSessionTokenSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [data.aws_kms_alias.ssm.target_key_arn]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "conversation_agent" {
  name              = "/aws/lambda/${local.name_prefix}-conversation-agent"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "conversation_agent" {
  function_name = "${local.name_prefix}-conversation-agent"
  role          = aws_iam_role.conversation_agent.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  filename         = data.archive_file.conversation_agent.output_path
  source_code_hash = data.archive_file.conversation_agent.output_base64sha256

  environment {
    variables = {
      CASE_STORE_TABLE_NAME           = var.case_store_table_name
      UNDERSTANDING_BACKEND           = "bedrock"
      BEDROCK_MODEL_ID_PARAM_NAME     = var.bedrock_model_id_ssm_parameter_name
      BEDROCK_REGION_PARAM_NAME       = var.bedrock_region_ssm_parameter_name
      SESSION_TOKEN_SECRET_PARAM_NAME = var.session_token_secret_parameter_name
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_cloudwatch_log_group.conversation_agent,
    aws_iam_role_policy_attachment.conversation_agent_basic_logs,
    aws_iam_role_policy.conversation_agent_dynamodb,
    aws_iam_role_policy.conversation_agent_bedrock,
    aws_iam_role_policy.conversation_agent_ssm,
  ]
}

# =====================================================================
# policy-agent -- capa Decide.
# IAM de mínimo privilegio: logging + (fase "Habilitar Bedrock real")
# bedrock:InvokeModel/Converse scoped al inference profile elegido, y
# ssm:GetParameter scoped a los 2 parámetros de config de Bedrock -- patrón
# "el modelo propone, policies.yaml dispone": Bedrock solo puede PROPONER,
# el guardrail determinístico sigue siendo policies.yaml embebido en el
# propio paquete. Deliberadamente SIN DynamoDB, SIN lambda:InvokeFunction
# sobre ningún recurso -- no toca ningún dato ni invoca a nadie.
# =====================================================================
resource "aws_iam_role" "policy_agent" {
  name               = "${local.name_prefix}-policy-agent-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "policy_agent_basic_logs" {
  role       = aws_iam_role.policy_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "policy_agent_bedrock" {
  name = "${local.name_prefix}-policy-agent-bedrock"
  role = aws_iam_role.policy_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeBedrockInferenceProfile"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:Converse",
        ]
        Resource = local.bedrock_resource_arns
      }
    ]
  })
}

resource "aws_iam_role_policy" "policy_agent_ssm" {
  name = "${local.name_prefix}-policy-agent-ssm"
  role = aws_iam_role.policy_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadBedrockConfigParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = local.bedrock_ssm_parameter_arns
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "policy_agent" {
  name              = "/aws/lambda/${local.name_prefix}-policy-agent"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "policy_agent" {
  function_name = "${local.name_prefix}-policy-agent"
  role          = aws_iam_role.policy_agent.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  filename         = data.archive_file.policy_agent.output_path
  source_code_hash = data.archive_file.policy_agent.output_base64sha256

  environment {
    variables = {
      POLICY_FILE_PATH            = "/var/task/policies.yaml"
      BEDROCK_MODEL_ID_PARAM_NAME = var.bedrock_model_id_ssm_parameter_name
      BEDROCK_REGION_PARAM_NAME   = var.bedrock_region_ssm_parameter_name
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_cloudwatch_log_group.policy_agent,
    aws_iam_role_policy_attachment.policy_agent_basic_logs,
    aws_iam_role_policy.policy_agent_bedrock,
    aws_iam_role_policy.policy_agent_ssm,
  ]
}

# =====================================================================
# retrieval-agent -- capa Act (informativa).
# IAM de mínimo privilegio: SOLO lectura (GetItem, Scan) sobre la tabla de
# catálogo. Sin permisos de escritura, sin lambda:InvokeFunction. No invoca
# Bedrock -- sigue siendo lookup determinístico sobre DynamoDB.
# =====================================================================
resource "aws_iam_role" "retrieval_agent" {
  name               = "${local.name_prefix}-retrieval-agent-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "retrieval_agent_basic_logs" {
  role       = aws_iam_role.retrieval_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "retrieval_agent_dynamodb" {
  name = "${local.name_prefix}-retrieval-agent-dynamodb"
  role = aws_iam_role.retrieval_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Scan",
        ]
        Resource = [var.catalog_table_arn]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "retrieval_agent" {
  name              = "/aws/lambda/${local.name_prefix}-retrieval-agent"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "retrieval_agent" {
  function_name = "${local.name_prefix}-retrieval-agent"
  role          = aws_iam_role.retrieval_agent.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  filename         = data.archive_file.retrieval_agent.output_path
  source_code_hash = data.archive_file.retrieval_agent.output_base64sha256

  environment {
    variables = {
      CATALOG_BACKEND    = "dynamodb"
      CATALOG_TABLE_NAME = var.catalog_table_name
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_cloudwatch_log_group.retrieval_agent,
    aws_iam_role_policy_attachment.retrieval_agent_basic_logs,
    aws_iam_role_policy.retrieval_agent_dynamodb,
  ]
}

# =====================================================================
# transaction-agent -- capa Act (transaccional/elegibilidad).
# IAM de mínimo privilegio: GetItem/PutItem sobre case_store (idempotency
# key + persistencia del resultado de elegibilidad), más (fase "matcher de
# transacciones disputadas") bedrock:InvokeModel scoped al foundation-model
# de Titan Embeddings y ssm:GetParameter scoped al parámetro de su model
# ID -- usado SOLO para desambiguar transacciones candidatas ambiguas en el
# flujo de disputa (services/transaction-agent/src/matching/), nunca para
# el cálculo de elegibilidad en sí, que sigue siendo determinístico
# (policies.yaml embebido). Sin lambda:InvokeFunction.
# =====================================================================
resource "aws_iam_role" "transaction_agent" {
  name               = "${local.name_prefix}-transaction-agent-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "transaction_agent_basic_logs" {
  role       = aws_iam_role.transaction_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "transaction_agent_dynamodb" {
  name = "${local.name_prefix}-transaction-agent-dynamodb"
  role = aws_iam_role.transaction_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
        ]
        Resource = [var.case_store_table_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "transaction_agent_bedrock" {
  name = "${local.name_prefix}-transaction-agent-bedrock"
  role = aws_iam_role.transaction_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeTitanEmbeddings"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = [local.embedding_foundation_model_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "transaction_agent_ssm" {
  name = "${local.name_prefix}-transaction-agent-ssm"
  role = aws_iam_role.transaction_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadEmbeddingConfigParameter"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = local.embedding_ssm_parameter_arns
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "transaction_agent" {
  name              = "/aws/lambda/${local.name_prefix}-transaction-agent"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "transaction_agent" {
  function_name = "${local.name_prefix}-transaction-agent"
  role          = aws_iam_role.transaction_agent.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  filename         = data.archive_file.transaction_agent.output_path
  source_code_hash = data.archive_file.transaction_agent.output_base64sha256

  environment {
    variables = {
      CASE_STORE_TABLE_NAME         = var.case_store_table_name
      POLICY_FILE_PATH              = "/var/task/policies.yaml"
      EMBEDDING_MODEL_ID_PARAM_NAME = var.embedding_model_id_ssm_parameter_name
      EMBEDDING_REGION              = var.embedding_region
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_cloudwatch_log_group.transaction_agent,
    aws_iam_role_policy_attachment.transaction_agent_basic_logs,
    aws_iam_role_policy.transaction_agent_dynamodb,
    aws_iam_role_policy.transaction_agent_bedrock,
    aws_iam_role_policy.transaction_agent_ssm,
  ]
}

# =====================================================================
# verification-agent -- capa Verify.
# IAM de mínimo privilegio: SOLO logging (AWSLambdaBasicExecutionRole).
# Task-a-Task interno (nunca detrás de API Gateway), mismo criterio que
# policy-agent: SIN DynamoDB, SIN lambda:InvokeFunction sobre ningún
# recurso -- hace una segunda verificación INDEPENDIENTE del resultado ya
# calculado por retrieval-agent/transaction-agent, releyendo
# policies.yaml embebido en su propio paquete, sin tocar ningún dato ni
# invocar a nadie. No invoca Bedrock -- fuera del scope de esta fase.
# =====================================================================
resource "aws_iam_role" "verification_agent" {
  name               = "${local.name_prefix}-verification-agent-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "verification_agent_basic_logs" {
  role       = aws_iam_role.verification_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "verification_agent" {
  name              = "/aws/lambda/${local.name_prefix}-verification-agent"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "verification_agent" {
  function_name = "${local.name_prefix}-verification-agent"
  role          = aws_iam_role.verification_agent.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  filename         = data.archive_file.verification_agent.output_path
  source_code_hash = data.archive_file.verification_agent.output_base64sha256

  environment {
    variables = {
      POLICY_FILE_PATH = "/var/task/policies.yaml"
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_cloudwatch_log_group.verification_agent,
    aws_iam_role_policy_attachment.verification_agent_basic_logs,
  ]
}

# =====================================================================
# escalation-agent -- capa Escalate.
# IAM de mínimo privilegio: SOLO logging (AWSLambdaBasicExecutionRole).
# Task-a-Task interno (nunca detrás de API Gateway), mismo criterio que
# policy-agent/verification-agent: SIN DynamoDB, SIN lambda:InvokeFunction.
# Pura transformación de datos ya recibidos en el evento (understand +
# policyDecision/verification) -- no lee policies.yaml ni ningún otro
# archivo de configuración en runtime, por eso no tiene bloque `environment`.
# =====================================================================
resource "aws_iam_role" "escalation_agent" {
  name               = "${local.name_prefix}-escalation-agent-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "escalation_agent_basic_logs" {
  role       = aws_iam_role.escalation_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "escalation_agent" {
  name              = "/aws/lambda/${local.name_prefix}-escalation-agent"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "escalation_agent" {
  function_name = "${local.name_prefix}-escalation-agent"
  role          = aws_iam_role.escalation_agent.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  filename         = data.archive_file.escalation_agent.output_path
  source_code_hash = data.archive_file.escalation_agent.output_base64sha256

  tags = local.common_tags

  depends_on = [
    aws_cloudwatch_log_group.escalation_agent,
    aws_iam_role_policy_attachment.escalation_agent_basic_logs,
  ]
}

# =====================================================================
# auth-agent -- login de plataforma (POST /auth/login).
# IAM de mínimo privilegio: logging + ssm:GetParameter/kms:Decrypt scoped
# al ÚNICO parámetro del secreto de sesión (mismo par de statements que
# conversation_agent_ssm, ver arriba). Expuesto vía API Gateway
# (terraform/modules/edge), NUNCA invocado por la Step Function -- SIN
# DynamoDB, SIN lambda:InvokeFunction, mismo criterio que
# conversation-agent (los dos únicos Lambdas de este módulo detrás de API
# Gateway). No lee policies.yaml.
# =====================================================================
resource "aws_iam_role" "auth_agent" {
  name               = "${local.name_prefix}-auth-agent-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "auth_agent_basic_logs" {
  role       = aws_iam_role.auth_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "auth_agent_ssm" {
  name = "${local.name_prefix}-auth-agent-ssm"
  role = aws_iam_role.auth_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSessionTokenSecret"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [var.session_token_secret_parameter_arn, var.resend_api_key_parameter_arn, var.otp_inbox_override_parameter_arn]
      },
      {
        Sid      = "DecryptSessionTokenSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [data.aws_kms_alias.ssm.target_key_arn]
      }
    ]
  })
}

# Login por código OTP dentro del chat (services/auth-agent/src/otp) --
# permisos de mínimo privilegio scoped al ARN exacto de la tabla nueva, sin
# batch/scan (el acceso siempre es por pk = document_id, ver otp/store.ts).
resource "aws_iam_role_policy" "auth_agent_otp_table" {
  name = "${local.name_prefix}-auth-agent-otp-table"
  role = aws_iam_role.auth_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OtpCodesReadWrite"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
        Resource = [var.otp_table_arn]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "auth_agent" {
  name              = "/aws/lambda/${local.name_prefix}-auth-agent"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "auth_agent" {
  function_name = "${local.name_prefix}-auth-agent"
  role          = aws_iam_role.auth_agent.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  filename         = data.archive_file.auth_agent.output_path
  source_code_hash = data.archive_file.auth_agent.output_base64sha256

  environment {
    variables = {
      SESSION_TOKEN_SECRET_PARAM_NAME = var.session_token_secret_parameter_name
      RESEND_API_KEY_PARAM_NAME       = var.resend_api_key_parameter_name
      RESEND_FROM_EMAIL               = var.resend_from_email
      OTP_INBOX_PARAM_NAME            = var.otp_inbox_override_parameter_name
      OTP_TABLE_NAME                  = var.otp_table_name
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_cloudwatch_log_group.auth_agent,
    aws_iam_role_policy_attachment.auth_agent_basic_logs,
    aws_iam_role_policy.auth_agent_ssm,
    aws_iam_role_policy.auth_agent_otp_table,
  ]
}
