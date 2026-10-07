import type { Customer } from "@banking-agent/transaction-agent/dist/data/mock-core-banking";
import type { LanguageCode } from "@banking-agent/shared";
import { findVerifiedCustomer } from "../login";
import { generateOtpCode, hashOtpCode } from "./code";
import { maskEmail } from "./mask-email";
import { sendOtpEmail } from "./resend-client";
import { REQUEST_COOLDOWN_MS, type DynamoDbOtpStore } from "./store";

/**
 * Paso 1 (de 2) de login -- ÚNICO camino de login desde la decisión de
 * seguridad del usuario (ver docs/STATUS.md, "Login con código por email
 * obligatorio"): documento + nombre + apellido (primer factor, `../login.ts`
 * `findVerifiedCustomer`) -> si matchea, código de 6 dígitos enviado por
 * email (segundo factor). El token real solo se mintea en el paso 2
 * (`otp/verify.ts`), nunca acá -- antes de esta fase, un documento+nombre
 * correcto ya minteaba el token directo (`attemptLogin`, retirado); ahora
 * SIEMPRE hace falta además el código.
 *
 * **Respuesta SIEMPRE genérica** (`{ok:true}`), matchee o no el documento/
 * nombre -- mismo criterio anti-enumeración que la función retirada:
 * revelar cuál de los dos falló (o si el documento existe) le permitiría a
 * un atacante enumerar documentos/nombres válidos. El mensaje al usuario es
 * siempre "si tus datos son correctos, te llegó un código" -- nunca se
 * distingue.
 */

export interface OtpRequestRequest {
  document_id: string;
  first_name: string;
  last_name: string;
  language: LanguageCode;
}

export type OtpRequestResult = { ok: true } | { ok: false; reason: "invalid_request" };

export interface OtpRequestDeps {
  customers: readonly Customer[];
  store: DynamoDbOtpStore;
  resendApiKey: string;
  fromEmail: string;
  /** Destino fijado por el admin (`getOtpInboxOverride`); `null` = el email del cliente. */
  inboxOverride: string | null;
  /** Inyectable para tests -- default es el cliente real de Resend. */
  sendEmail?: typeof sendOtpEmail;
  /** Inyectable para tests -- default `Date.now`. */
  now?: () => number;
}

export async function attemptOtpRequest(
  request: Partial<OtpRequestRequest>,
  deps: OtpRequestDeps
): Promise<OtpRequestResult> {
  const language: LanguageCode = request.language === "pt" ? "pt" : "es";

  // Nunca llega a buscar en `customers` con campos vacíos -- este SÍ es un
  // error distinguible del "no matchea" de abajo porque no depende de
  // ningún dato de negocio (mismo criterio que la función retirada).
  if (
    typeof request.document_id !== "string" ||
    !request.document_id.trim() ||
    typeof request.first_name !== "string" ||
    !request.first_name.trim() ||
    typeof request.last_name !== "string" ||
    !request.last_name.trim()
  ) {
    return { ok: false, reason: "invalid_request" };
  }

  const documentId = request.document_id.trim();
  const customer = findVerifiedCustomer(request, deps.customers);
  const now = (deps.now ?? Date.now)();

  // Documento inexistente O nombre que no matchea: respuesta genérica
  // idéntica, sin tocar el store ni enviar ningún email -- nada que hacer
  // más allá de simular el mismo tiempo de respuesta que el camino feliz
  // (no medido acá explícitamente, limitación conocida -- ver
  // docs/EVALUATION-CRITERIA.md).
  if (!customer) {
    return { ok: true };
  }

  const existing = await deps.store.get(documentId);
  if (existing.status === "found" && now - existing.value.lastRequestedAt < REQUEST_COOLDOWN_MS) {
    // En cooldown -- no se reenvía, pero la respuesta es la MISMA que si se
    // hubiera enviado (nunca se le dice al usuario "esperá N segundos" de
    // forma que revele que el documento existe).
    return { ok: true };
  }

  const code = generateOtpCode();
  const codeHash = hashOtpCode(code);
  await deps.store.put({ documentId, codeHash, customerId: customer.customer_id, lastRequestedAt: now });

  const send = deps.sendEmail ?? sendOtpEmail;
  const toEmail = deps.inboxOverride ?? customer.email;
  const emailResult = await send({
    toEmail,
    code,
    language,
    apiKey: deps.resendApiKey,
    fromEmail: deps.fromEmail,
  });

  if (!emailResult.ok) {
    // eslint-disable-next-line no-console
    console.error("auth-agent otp email send failed", { documentId, email: maskEmail(toEmail) });
  }

  return { ok: true };
}
