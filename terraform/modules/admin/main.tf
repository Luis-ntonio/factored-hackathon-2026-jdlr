# =============================================================================
# admin-agent -- dashboard de admin (interno, NUNCA un cliente bancario).
# Lambda invocado DIRECTO por API Gateway (nunca por la Step Function,
# mismo criterio que auth-agent en terraform/modules/agent) -- 2 rutas:
# listar conversaciones reales (Scan sobre case-store) y traza completa de
# un caso (FilterLogEvents sobre el log group de la Step Function, que YA
# loguea todo -- ver services/admin-agent/src/get-trace.ts).
#
# Módulo SEPARADO de `modules/agent` a propósito (no un 8vo Lambda ahí
# adentro): admin-agent depende del log group de `modules/orchestration`, y
# `modules/orchestration` YA depende de `modules/agent` (los ARNs de los 6
# Lambdas de negocio que invoca la Step Function) -- meter admin-agent
# DENTRO de `modules/agent` hubiera creado una dependencia circular real
# entre agent <-> orchestration. Como módulo propio, declarado DESPUÉS de
# ambos en `terraform/envs/dev/main.tf` (con `depends_on = [module.agent]`
# explícito porque el zip se genera en el build de ESE módulo, ver abajo),
# el grafo queda: agent -> orchestration, agent -> admin, orchestration ->
# admin -- nunca un ciclo.
#
# El zip de este Lambda se genera en el MISMO build de esbuild que el resto
# de servicios (`terraform/scripts/package-lambdas.js`, admin-agent es el
# 8vo entry de `LAMBDAS`) -- ese script ya corre dentro de
# `null_resource.build_lambdas` de `modules/agent`, así que este módulo
# SOLO empaqueta el zip ya generado ahí (`../agent/build/admin-agent`),
# nunca dispara esbuild de nuevo.
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "admin"
    },
    var.tags
  )

  # Simulador de conversaciones -- MISMO cálculo de ARNs de Bedrock que
  # `terraform/modules/agent/main.tf` (copiado literal, ese local no es
  # importable entre módulos de Terraform): nunca `Resource = "*"`, scoped
  # al inference profile + al foundation model subyacente en las 3
  # regiones que cubre el enrutamiento cross-region del prefijo "us."
  # (verificado empíricamente, ver README.md de modules/agent).
  bedrock_inference_profile_arn = "arn:aws:bedrock:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}"

  bedrock_foundation_model_arns = [
    for region in ["us-east-1", "us-east-2", "us-west-2"] :
    "arn:aws:bedrock:${region}::foundation-model/${replace(var.bedrock_model_id, "us.", "")}"
  ]

  bedrock_resource_arns = concat(
    [local.bedrock_inference_profile_arn],
    local.bedrock_foundation_model_arns,
  )

  bedrock_ssm_parameter_arns = [
    "arn:aws:ssm:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:parameter${var.bedrock_model_id_ssm_parameter_name}",
    "arn:aws:ssm:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:parameter${var.bedrock_region_ssm_parameter_name}",
  ]
}

data "aws_caller_identity" "current" {}

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

# Clave KMS administrada por AWS que cifra el parámetro SecureString de
# admin_api_key -- mismo patrón que modules/agent (auth_agent/
# conversation_agent).
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

data "archive_file" "admin_agent" {
  type        = "zip"
  source_dir  = "${path.module}/../agent/build/admin-agent"
  output_path = "${path.module}/../agent/build/admin-agent.zip"
}

resource "aws_iam_role" "admin_agent" {
  name               = "${local.name_prefix}-admin-agent-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "admin_agent_basic_logs" {
  role       = aws_iam_role.admin_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# dynamodb:Scan (listConversations, solo LECTURA sobre conversaciones
# reales de clientes) + dynamodb:PutItem/GetItem (store de corridas de
# simulación, items propios "SIM#<runId>", nunca tocan items de clientes) +
# dynamodb:Query sobre el GSI by-customer (listSimulationRuns,
# gsi1pk="SIMULATIONS") -- misma tabla, nunca una tabla nueva.
resource "aws_iam_role_policy" "admin_agent_dynamodb" {
  name = "${local.name_prefix}-admin-agent-dynamodb"
  role = aws_iam_role.admin_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ScanConversations"
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
        Resource = [var.case_store_table_arn]
      },
      {
        Sid      = "ReadWriteSimulationRuns"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = [var.case_store_table_arn]
      },
      {
        Sid      = "QuerySimulationRunsByIndex"
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = [var.case_store_table_by_customer_index_arn]
      }
    ]
  })
}

# bedrock:InvokeModel/Converse scoped al inference profile elegido (mismo
# patrón/ARNs que modules/agent) -- usado por el simulador de usuario
# (services/admin-agent/src/simulation/user-simulator.ts) para generar el
# próximo mensaje del cliente sintético, nunca para decidir pass/fail (eso
# es una comparación estructural en run-simulation.ts).
resource "aws_iam_role_policy" "admin_agent_bedrock" {
  name = "${local.name_prefix}-admin-agent-bedrock"
  role = aws_iam_role.admin_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:Converse"]
        Resource = local.bedrock_resource_arns
      }
    ]
  })
}

# ssm:GetParameter sobre los MISMOS 2 parámetros de config de Bedrock que
# ya leen conversation-agent/policy-agent (module.secrets) -- sin
# kms:Decrypt porque esos 2 parámetros son String plano, no SecureString
# (ver terraform/modules/secrets/variables.tf).
resource "aws_iam_role_policy" "admin_agent_bedrock_ssm" {
  name = "${local.name_prefix}-admin-agent-bedrock-ssm"
  role = aws_iam_role.admin_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = local.bedrock_ssm_parameter_arns
      }
    ]
  })
}

# Mínimo privilegio: SOLO logs:FilterLogEvents (nunca logs:PutLogEvents ni
# ninguna acción de escritura) sobre el log group PUNTUAL de la Step
# Function -- admin-agent lee logs que YA se generan, nunca agrega
# logging nuevo.
resource "aws_iam_role_policy" "admin_agent_logs" {
  name = "${local.name_prefix}-admin-agent-logs"
  role = aws_iam_role.admin_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOrchestratorLogs"
        Effect   = "Allow"
        Action   = ["logs:FilterLogEvents"]
        Resource = [var.state_machine_log_group_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "admin_agent_ssm" {
  name = "${local.name_prefix}-admin-agent-ssm"
  role = aws_iam_role.admin_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadAdminApiKey"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [var.admin_api_key_parameter_arn]
      },
      {
        Sid      = "DecryptAdminApiKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [data.aws_kms_alias.ssm.target_key_arn]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "admin_agent" {
  name              = "/aws/lambda/${local.name_prefix}-admin-agent"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "admin_agent" {
  function_name = "${local.name_prefix}-admin-agent"
  role          = aws_iam_role.admin_agent.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  filename         = data.archive_file.admin_agent.output_path
  source_code_hash = data.archive_file.admin_agent.output_base64sha256

  environment {
    variables = {
      CASE_STORE_TABLE_NAME        = var.case_store_table_name
      STATE_MACHINE_LOG_GROUP_NAME = var.state_machine_log_group_name
      ADMIN_API_KEY_PARAM_NAME     = var.admin_api_key_parameter_name
      OTP_INBOX_PARAM_NAME         = var.otp_inbox_override_parameter_name
      # Simulador de conversaciones.
      BEDROCK_MODEL_ID_PARAM_NAME = var.bedrock_model_id_ssm_parameter_name
      BEDROCK_REGION_PARAM_NAME   = var.bedrock_region_ssm_parameter_name
      CHAT_API_URL                = var.chat_api_endpoint
      AUTH_LOGIN_URL              = var.auth_login_endpoint
      # Literal (no `aws_lambda_function.admin_agent.function_name` -- un
      # recurso no puede referenciar su propio atributo dentro de su propio
      # bloque): MISMA expresión que `function_name` arriba, para el
      # self-invoke asíncrono del worker (`POST /admin/simulations` en
      # services/admin-agent/src/index.ts).
      ADMIN_AGENT_FUNCTION_NAME = "${local.name_prefix}-admin-agent"
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_cloudwatch_log_group.admin_agent,
    aws_iam_role_policy_attachment.admin_agent_basic_logs,
    aws_iam_role_policy.admin_agent_dynamodb,
    aws_iam_role_policy.admin_agent_logs,
    aws_iam_role_policy.admin_agent_ssm,
    aws_iam_role_policy.admin_agent_bedrock,
    aws_iam_role_policy.admin_agent_bedrock_ssm,
  ]
}

# lambda:InvokeFunction scoped a SU PROPIO ARN -- self-invoke asíncrono
# (`InvocationType: "Event"`) del worker de simulación, disparado por la
# propia ruta `POST /admin/simulations` ya autenticada (nunca expuesto por
# API Gateway). No es una dependencia circular: esta policy referencia el
# ARN YA RESUELTO del Lambda de arriba, declarada DESPUÉS de él -- mismo
# patrón que cualquier recurso referenciando su propio ARN en una policy
# adjunta aparte.
resource "aws_iam_role_policy" "admin_agent_self_invoke" {
  name = "${local.name_prefix}-admin-agent-self-invoke"
  role = aws_iam_role.admin_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.admin_agent.arn]
      }
    ]
  })
}
