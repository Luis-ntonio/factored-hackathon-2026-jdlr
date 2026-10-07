locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "edge"
    },
    var.tags
  )
}

# API Gateway HTTP como punto de ingreso del chat UI (frontend-dev).
#
# Checkpoint 0: scaffold vacío / mínimo. NO tiene:
#   - WAF                -> ver README.md de este módulo (limitación conocida,
#                            documentada, no silenciada; impacta Security).
#   - Autenticación/authZ -> ver README.md (limitación conocida, misma razón).
# La integración de negocio (dispatcher -> Step Function) se conecta desde
# checkpoint "pipeline end-to-end sobre AWS real" vía
# var.attach_chat_route/var.chat_route_lambda_invoke_arn (ver variables.tf).
#
# CORS ("Días 6-7 — Frontend", docs/PLAN.md): el `cors_configuration` nativo
# de HTTP API hace dos cosas sin tocar el Lambda dispatcher (que no es
# ownership de este agente):
#   1. Responde el preflight `OPTIONS /chat` directamente desde API Gateway
#      (nunca llega al Lambda).
#   2. Inyecta los headers `Access-Control-Allow-*` en la respuesta real que
#      sí devuelve el Lambda (AWS_PROXY), sin que el código del dispatcher
#      necesite agregarlos.
# Ver README.md de este módulo para la decisión de `allow_origins = ["*"]`
# (limitación conocida de Security, igual que la falta de WAF/auth).
resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name_prefix}-chat-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.cors_allow_origins
    # GET agregado para las 2 rutas del dashboard de admin (GET
    # /admin/conversations, GET /admin/conversations/{caseId}/trace) --
    # antes solo POST/OPTIONS (chat/auth). x-admin-key agregado por el
    # mismo motivo: un header custom (no "simple") SIEMPRE dispara
    # preflight CORS, y sin declararlo acá el navegador bloquea la
    # respuesta real aunque el Lambda la devuelva bien.
    allow_methods = ["POST", "GET", "PUT", "OPTIONS"]
    allow_headers = ["content-type", "x-admin-key"]
    max_age       = 300
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "access_logs" {
  name              = "/aws/apigateway/${local.name_prefix}-chat-api"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access_logs.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      protocol         = "$context.protocol"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  tags = local.common_tags
}

# Integración + ruta del chat. `count` depende de `var.attach_chat_route`
# (booleano LITERAL, siempre conocido en plan time) y NUNCA de
# `var.chat_route_lambda_invoke_arn != null` directamente -- ese ARN puede
# ser "known after apply" cuando el Lambda que lo produce (el dispatcher de
# modules/orchestration) se crea en la misma corrida de `terraform apply`,
# y Terraform no puede evaluar un `count` a partir de un valor unknown en
# plan time. Ver docstring de `var.attach_chat_route` en variables.tf.
resource "aws_apigatewayv2_integration" "chat" {
  count = var.attach_chat_route ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.chat_route_lambda_invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "chat" {
  count = var.attach_chat_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.chat_route_key
  target    = "integrations/${aws_apigatewayv2_integration.chat[0].id}"
}

# Integración + ruta de login (POST /auth/login) -- mismo mecanismo
# count/attach_*_route que el chat de arriba, pero apunta DIRECTO al Lambda
# auth-agent (modules/agent), nunca a un dispatcher/Step Function: login es
# una sola invocación sin orquestación, no un turno del pipeline
# Understand->Decide->Act->Verify->Escalate.
resource "aws_apigatewayv2_integration" "auth" {
  count = var.attach_auth_route ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.auth_route_lambda_invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "auth" {
  count = var.attach_auth_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.auth_route_key
  target    = "integrations/${aws_apigatewayv2_integration.auth[0].id}"
}

# Rutas del login por código OTP (documento + código por email, dentro del
# chat) -- reusan la MISMA integración de arriba (mismo Lambda auth-agent,
# que despacha por `event.rawPath`), no hace falta una integración nueva.
resource "aws_apigatewayv2_route" "otp_request" {
  count = var.attach_auth_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.otp_request_route_key
  target    = "integrations/${aws_apigatewayv2_integration.auth[0].id}"
}

resource "aws_apigatewayv2_route" "otp_verify" {
  count = var.attach_auth_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.otp_verify_route_key
  target    = "integrations/${aws_apigatewayv2_integration.auth[0].id}"
}

# Mismo criterio que la integración de auth de arriba (count/attach_*_route
# separado del ARN, DIRECTO al Lambda admin-agent, nunca vía Step
# Function) -- dashboard de admin, superficie interna separada del chat.
resource "aws_apigatewayv2_integration" "admin" {
  count = var.attach_admin_route ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.admin_route_lambda_invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "admin_conversations" {
  count = var.attach_admin_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.admin_conversations_route_key
  target    = "integrations/${aws_apigatewayv2_integration.admin[0].id}"
}

# Misma integración de arriba (mismo Lambda admin-agent, que despacha por
# `event.rawPath`) -- no hace falta una integración nueva.
resource "aws_apigatewayv2_route" "admin_trace" {
  count = var.attach_admin_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.admin_trace_route_key
  target    = "integrations/${aws_apigatewayv2_integration.admin[0].id}"
}

# Simulador de conversaciones -- 3 rutas más, MISMA integración/Lambda
# (admin-agent despacha por rawPath + método HTTP, ver
# services/admin-agent/src/index.ts).
resource "aws_apigatewayv2_route" "admin_simulations_create" {
  count = var.attach_admin_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.admin_simulations_create_route_key
  target    = "integrations/${aws_apigatewayv2_integration.admin[0].id}"
}

resource "aws_apigatewayv2_route" "admin_simulations_list" {
  count = var.attach_admin_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.admin_simulations_list_route_key
  target    = "integrations/${aws_apigatewayv2_integration.admin[0].id}"
}

resource "aws_apigatewayv2_route" "admin_simulations_detail" {
  count = var.attach_admin_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.admin_simulations_detail_route_key
  target    = "integrations/${aws_apigatewayv2_integration.admin[0].id}"
}
