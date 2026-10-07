import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from "aws-lambda";
import { CUSTOMERS } from "@banking-agent/transaction-agent/dist/data/mock-core-banking";
import { getAuthConfig, getOtpConfig, getOtpInboxOverride } from "./config";
import { attemptOtpRequest, type OtpRequestRequest } from "./otp/request";
import { attemptOtpVerify, type OtpVerifyRequest } from "./otp/verify";
import { buildOtpDocClientFromEnv, DynamoDbOtpStore } from "./otp/store";

/**
 * Handler de Lambda para las rutas de auth-agent, despachadas por `rawPath`
 * (comparten la MISMA integración de API Gateway -- ver
 * `terraform/modules/edge` -- así que un solo Lambda/handler las atiende
 * todas, nunca uno separado para algo tan chico).
 *
 * Login SIEMPRE de 2 pasos desde la decisión de seguridad del usuario (ver
 * docs/STATUS.md, "Login con código por email obligatorio" -- "un
 * documento+nombre solo no prueba identidad lo suficiente si ese
 * documento+nombre puede filtrarse o publicarse", literal el caso de este
 * proyecto con los 2 clientes reales publicados en el README):
 *   - `POST /auth/login` y `POST /auth/otp/request` (mismo handler, mismo
 *     comportamiento -- 2 rutas por compatibilidad de naming con el
 *     frontend/historial, nunca 2 lógicas distintas): documento + nombre +
 *     apellido -> SI matchean contra el core bancario, dispara un código de
 *     un solo uso por email (Resend). SIEMPRE responde `{ok:true}` exista o
 *     no el documento/nombre -- ver docstring de `otp/request.ts`
 *     (anti-enumeración).
 *   - `POST /auth/otp/verify`: documento + código -> sessionToken,
 *     consumiendo el código (un solo uso). Único paso que mintea un token.
 *
 * Nunca devuelve 401/403 -- SIEMPRE 200 con `{ok: true, ...}` o
 * `{ok: false, reason}` en el body (mismo criterio de Reliability que el
 * resto del pipeline: nunca un 5xx sin body, el cliente HTTP decide cómo
 * reaccionar al campo `ok`).
 */
function parseBody<T>(event: APIGatewayProxyEventV2): Partial<T> {
  if (!event.body) return {};
  try {
    const raw = event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf-8") : event.body;
    return JSON.parse(raw) as Partial<T>;
  } catch {
    return {};
  }
}

function jsonResponse(body: unknown): APIGatewayProxyResultV2 {
  return { statusCode: 200, headers: { "content-type": "application/json" }, body: JSON.stringify(body) };
}

let otpStore: DynamoDbOtpStore | undefined;

function getOtpStore(tableName: string): DynamoDbOtpStore {
  if (!otpStore) {
    otpStore = new DynamoDbOtpStore({ tableName, docClient: buildOtpDocClientFromEnv() });
  }
  return otpStore;
}

export async function handler(event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> {
  const path = event.rawPath ?? "";

  try {
    if (path === "/auth/otp/verify") {
      const body = parseBody<OtpVerifyRequest>(event);
      const { sessionSecret } = await getAuthConfig();
      const otpConfig = await getOtpConfig();
      const result = await attemptOtpVerify(body, {
        customers: CUSTOMERS,
        store: getOtpStore(otpConfig.otpTableName),
        sessionSecret,
      });
      return jsonResponse(result);
    }

    // Default: /auth/login y /auth/otp/request, MISMO comportamiento --
    // ver docstring de arriba.
    const body = parseBody<OtpRequestRequest>(event);
    const otpConfig = await getOtpConfig();
    const inboxOverride = await getOtpInboxOverride();
    const result = await attemptOtpRequest(body, {
      customers: CUSTOMERS,
      store: getOtpStore(otpConfig.otpTableName),
      resendApiKey: otpConfig.resendApiKey,
      inboxOverride,
      fromEmail: otpConfig.resendFromEmail,
    });
    return jsonResponse(result);
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("auth-agent handler error", { path, error });
    return jsonResponse({ ok: false, reason: "invalid_request" });
  }
}
