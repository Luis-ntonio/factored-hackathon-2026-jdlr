variable "otp_inbox_override_parameter_name" {
  description = "Nombre del parámetro SSM con el destino override de los códigos OTP (module.secrets.otp_inbox_override_parameter_name). admin-agent lo lee y lo escribe desde PUT /admin/otp-inbox."
  type        = string
}

variable "otp_inbox_override_parameter_arn" {
  description = "ARN del mismo parámetro -- scoping exacto de la IAM policy de admin-agent (ssm:GetParameter + ssm:PutParameter)."
  type        = string
}

resource "aws_iam_role_policy" "admin_agent_otp_inbox" {
  name = "${local.name_prefix}-admin-agent-otp-inbox"
  role = aws_iam_role.admin_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OtpInboxReadWrite"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = [var.otp_inbox_override_parameter_arn]
      }
    ]
  })
}
