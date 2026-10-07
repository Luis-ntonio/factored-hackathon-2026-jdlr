variable "admin_otp_inbox_get_route_key" {
  description = "Route key HTTP para leer el destino override de los códigos OTP, usado solo si attach_admin_route = true."
  type        = string
  default     = "GET /admin/otp-inbox"
}

variable "admin_otp_inbox_put_route_key" {
  description = "Route key HTTP para cambiar el destino override de los códigos OTP, usado solo si attach_admin_route = true."
  type        = string
  default     = "PUT /admin/otp-inbox"
}

resource "aws_apigatewayv2_route" "admin_otp_inbox_get" {
  count = var.attach_admin_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.admin_otp_inbox_get_route_key
  target    = "integrations/${aws_apigatewayv2_integration.admin[0].id}"
}

resource "aws_apigatewayv2_route" "admin_otp_inbox_put" {
  count = var.attach_admin_route ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = var.admin_otp_inbox_put_route_key
  target    = "integrations/${aws_apigatewayv2_integration.admin[0].id}"
}
