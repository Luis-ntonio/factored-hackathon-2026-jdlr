import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";

/**
 * Resuelve en runtime el secreto HMAC de sesión desde SSM Parameter Store
 * (SecureString) -- mismo patrón de caché en memoria + reintentos acotados
 * que `services/policy-agent/src/bedrock/config.ts` (`getBedrockDeciderConfig`).
 *
 * Variable de entorno:
 *  - SESSION_TOKEN_SECRET_PARAM_NAME: nombre del parámetro SSM (ej.
 *    "/banking-agent-dev/auth/session_token_secret"), provisto por
 *    Terraform (`terraform/modules/secrets`, `random_password` +
 *    `aws_ssm_parameter` SecureString -- el mismo secreto que lee
 *    conversation-agent para VERIFICAR el token que este servicio firma).
 *
 * A diferencia de la config de Bedrock (que puede devolver `null` y seguir
 * operando sin el guardrail), acá si el secreto no está disponible el
 * servicio NO PUEDE firmar tokens de forma segura -- `getSessionSecret()`
 * lanza, y `handler.ts` lo captura en su try/catch de nivel superior para
 * responder un error genérico (nunca firmar con un secreto inventado /
 * hardcodeado como fallback).
 *
 * Deliberadamente SEPARADO de `getOtpConfig()` (abajo): `/auth/login` no
 * necesita ni depende de que Resend esté configurado -- acoplar los dos
 * secretos en una sola función rompería el login existente si el usuario
 * todavía no cargó la API key de Resend vía CLI.
 */

export interface AuthConfig {
  sessionSecret: string;
}

let cachedConfig: AuthConfig | null | undefined;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export interface GetAuthConfigOptions {
  /** Inyectable para tests -- nunca pega a AWS real desde `npm test`. */
  ssmClient?: Pick<SSMClient, "send">;
  maxRetries?: number;
  baseDelayMs?: number;
}

export async function getAuthConfig(options: GetAuthConfigOptions = {}): Promise<AuthConfig> {
  if (cachedConfig !== undefined && cachedConfig !== null) return cachedConfig;

  const paramName = process.env.SESSION_TOKEN_SECRET_PARAM_NAME;
  if (!paramName) {
    throw new Error("SESSION_TOKEN_SECRET_PARAM_NAME env var no configurada");
  }

  const maxRetries = options.maxRetries ?? 2;
  const baseDelayMs = options.baseDelayMs ?? 75;
  const ssmClient = options.ssmClient ?? new SSMClient({});

  let lastError: unknown;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const result = await ssmClient.send(new GetParameterCommand({ Name: paramName, WithDecryption: true }));
      const value = result.Parameter?.Value;
      if (typeof value !== "string" || value.length === 0) {
        throw new Error(`Parámetro SSM ${paramName} vacío o sin valor`);
      }
      cachedConfig = { sessionSecret: value };
      return cachedConfig;
    } catch (error) {
      lastError = error;
      if (attempt < maxRetries) {
        await sleep(baseDelayMs * Math.pow(2, attempt));
      }
    }
  }

  throw new Error(`No se pudo leer el secreto de sesión desde SSM (${paramName}): ${String(lastError)}`);
}

/** Solo para tests -- resetea el caché en memoria entre casos. */
export function resetAuthConfigCacheForTests(): void {
  cachedConfig = undefined;
}

/**
 * Config del flujo OTP: API key de Resend (SecureString en SSM, la carga el
 * usuario vía `aws ssm put-parameter --overwrite` fuera de Terraform -- ver
 * `terraform/modules/secrets`, `aws_ssm_parameter.resend_api_key` con
 * `lifecycle.ignore_changes`) + config no sensible leída directo del
 * entorno (`RESEND_FROM_EMAIL`, `OTP_TABLE_NAME`).
 *
 * Mismo criterio que `getAuthConfig`: si la API key no está disponible,
 * `getOtpConfig()` lanza -- `/auth/otp/request` responde error genérico,
 * nunca finge haber enviado un email que no salió.
 */
export interface OtpConfig {
  resendApiKey: string;
  resendFromEmail: string;
  otpTableName: string;
}

let cachedOtpConfig: OtpConfig | null | undefined;

export async function getOtpConfig(options: GetAuthConfigOptions = {}): Promise<OtpConfig> {
  if (cachedOtpConfig !== undefined && cachedOtpConfig !== null) return cachedOtpConfig;

  const paramName = process.env.RESEND_API_KEY_PARAM_NAME;
  const fromEmail = process.env.RESEND_FROM_EMAIL;
  const otpTableName = process.env.OTP_TABLE_NAME;
  if (!paramName || !fromEmail || !otpTableName) {
    throw new Error("RESEND_API_KEY_PARAM_NAME / RESEND_FROM_EMAIL / OTP_TABLE_NAME env vars no configuradas");
  }

  const maxRetries = options.maxRetries ?? 2;
  const baseDelayMs = options.baseDelayMs ?? 75;
  const ssmClient = options.ssmClient ?? new SSMClient({});

  let lastError: unknown;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const result = await ssmClient.send(new GetParameterCommand({ Name: paramName, WithDecryption: true }));
      const value = result.Parameter?.Value;
      if (typeof value !== "string" || value.length === 0) {
        throw new Error(`Parámetro SSM ${paramName} vacío o sin valor`);
      }
      cachedOtpConfig = { resendApiKey: value, resendFromEmail: fromEmail, otpTableName };
      return cachedOtpConfig;
    } catch (error) {
      lastError = error;
      if (attempt < maxRetries) {
        await sleep(baseDelayMs * Math.pow(2, attempt));
      }
    }
  }

  throw new Error(`No se pudo leer la API key de Resend desde SSM (${paramName}): ${String(lastError)}`);
}

/** Solo para tests -- resetea el caché en memoria entre casos. */
export function resetOtpConfigCacheForTests(): void {
  cachedOtpConfig = undefined;
}

const OTP_INBOX_NO_OVERRIDE = "none";
const OTP_INBOX_CACHE_TTL_MS = 30_000;

let cachedOtpInbox: { value: string | null; fetchedAt: number } | undefined;

/**
 * Destino de los códigos OTP cuando el admin lo fijó (`PUT /admin/otp-inbox`,
 * ver services/admin-agent/src/otp-inbox.ts). `null` = sin override, cada
 * cliente recibe el código en su propio email. Si SSM no responde, cae a
 * `null` (nunca bloquea el login), con caché corta para que un cambio se
 * note en ~30 segundos sin redeploy.
 */
export async function getOtpInboxOverride(options: GetAuthConfigOptions = {}): Promise<string | null> {
  const now = Date.now();
  if (cachedOtpInbox && now - cachedOtpInbox.fetchedAt < OTP_INBOX_CACHE_TTL_MS) {
    return cachedOtpInbox.value;
  }

  const paramName = process.env.OTP_INBOX_PARAM_NAME;
  if (!paramName) return null;

  const ssmClient = options.ssmClient ?? new SSMClient({});
  try {
    const result = await ssmClient.send(new GetParameterCommand({ Name: paramName }));
    const value = result.Parameter?.Value;
    const inbox = value && value !== OTP_INBOX_NO_OVERRIDE ? value : null;
    cachedOtpInbox = { value: inbox, fetchedAt: now };
    return inbox;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("auth-agent otp inbox override read failed", { paramName, error: String(error) });
    return null;
  }
}

/** Solo para tests -- resetea el caché en memoria entre casos. */
export function resetOtpInboxCacheForTests(): void {
  cachedOtpInbox = undefined;
}
