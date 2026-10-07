variable "otp_inbox_override_parameter_name" {
  description = "Nombre del parámetro SSM con el destino override de los códigos OTP (module.secrets.otp_inbox_override_parameter_name). auth-agent lo lee para enviar el código ahí."
  type        = string
}

variable "otp_inbox_override_parameter_arn" {
  description = "ARN del mismo parámetro -- scoping exacto de la IAM policy ssm:GetParameter de auth-agent."
  type        = string
}
