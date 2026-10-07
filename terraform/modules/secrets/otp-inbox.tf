resource "aws_ssm_parameter" "otp_inbox_override" {
  name        = "/${local.name_prefix}/otp/inbox_override"
  description = "Destino de TODOS los códigos OTP de login. 'none' = cada cliente recibe el suyo. Lo cambian los evaluadores con PUT /admin/otp-inbox (services/admin-agent)."
  type        = "String"
  value       = "none"

  lifecycle {
    ignore_changes = [value]
  }

  tags = local.common_tags
}

output "otp_inbox_override_parameter_name" {
  description = "Nombre del parámetro SSM con el destino override de los códigos OTP."
  value       = aws_ssm_parameter.otp_inbox_override.name
}

output "otp_inbox_override_parameter_arn" {
  description = "ARN del parámetro SSM del destino override -- para la IAM policy de auth-agent (lectura) y admin-agent (lectura/escritura)."
  value       = aws_ssm_parameter.otp_inbox_override.arn
}
