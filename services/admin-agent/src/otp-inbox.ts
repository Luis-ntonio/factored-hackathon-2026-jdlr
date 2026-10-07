import { GetParameterCommand, PutParameterCommand, SSMClient } from "@aws-sdk/client-ssm";

/**
 * Destino de TODOS los códigos OTP de login (ver `services/auth-agent/src/
 * config.ts`, `getOtpInboxOverride`). Vive en un parámetro SSM String que
 * Terraform crea con valor `none` (sin override -- cada cliente recibe el
 * código en su propio `email`). Los evaluadores de la hackathon lo cambian
 * con `PUT /admin/otp-inbox` (misma `x-admin-key` que el resto del admin).
 */
export const OTP_INBOX_NO_OVERRIDE = "none";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function isValidOtpInboxEmail(value: unknown): value is string {
  return typeof value === "string" && value.length <= 254 && EMAIL_PATTERN.test(value);
}

export interface OtpInboxDeps {
  paramName: string;
  ssmClient: Pick<SSMClient, "send">;
}

export async function getOtpInbox(deps: OtpInboxDeps): Promise<string | null> {
  const result = await deps.ssmClient.send(new GetParameterCommand({ Name: deps.paramName }));
  const value = result.Parameter?.Value;
  return value && value !== OTP_INBOX_NO_OVERRIDE ? value : null;
}

export async function setOtpInbox(email: string, deps: OtpInboxDeps): Promise<void> {
  await deps.ssmClient.send(
    new PutParameterCommand({ Name: deps.paramName, Type: "String", Value: email, Overwrite: true })
  );
}
