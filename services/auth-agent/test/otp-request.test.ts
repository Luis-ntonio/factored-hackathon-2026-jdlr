import { describe, expect, it, vi } from "vitest";
import { CUSTOMERS } from "@banking-agent/transaction-agent/dist/data/mock-core-banking";
import { attemptOtpRequest } from "../src/otp/request";
import { REQUEST_COOLDOWN_MS } from "../src/otp/store";
import { FakeOtpStore } from "./fakes/fake-otp-store";

const MARIA_DOCUMENT = "LOTM900101MDFPRR09";
const MARIA_FIRST_NAME = "María Fernanda";
const MARIA_LAST_NAME = "López Torres";

function deps(overrides: Partial<Parameters<typeof attemptOtpRequest>[1]> = {}) {
  return {
    customers: CUSTOMERS,
    store: new FakeOtpStore() as unknown as Parameters<typeof attemptOtpRequest>[1]["store"],
    resendApiKey: "test-key",
    fromEmail: "no-reply@phonance.com",
    inboxOverride: null,
    sendEmail: vi.fn().mockResolvedValue({ ok: true }),
    ...overrides,
  };
}

describe("attemptOtpRequest -- paso 1 de 2 del login (documento + nombre + apellido)", () => {
  it("documento + nombre + apellido correctos -> {ok:true} y dispara el envío de email", async () => {
    const sendEmail = vi.fn().mockResolvedValue({ ok: true });
    const result = await attemptOtpRequest(
      { document_id: MARIA_DOCUMENT, first_name: MARIA_FIRST_NAME, last_name: MARIA_LAST_NAME, language: "es" },
      deps({ sendEmail })
    );

    expect(result).toEqual({ ok: true });
    expect(sendEmail).toHaveBeenCalledTimes(1);
    const call = sendEmail.mock.calls[0][0];
    expect(call.toEmail).toContain("@");
    expect(call.code).toMatch(/^\d{6}$/);
  });

  it("con inboxOverride fijado por el admin, el código va a ese destino y no al email del cliente", async () => {
    const sendEmail = vi.fn().mockResolvedValue({ ok: true });
    await attemptOtpRequest(
      { document_id: MARIA_DOCUMENT, first_name: MARIA_FIRST_NAME, last_name: MARIA_LAST_NAME, language: "es" },
      deps({ sendEmail, inboxOverride: "juez@example.com" })
    );

    expect(sendEmail).toHaveBeenCalledTimes(1);
    expect(sendEmail.mock.calls[0][0].toEmail).toBe("juez@example.com");
  });

  it("documento inexistente -> MISMA respuesta {ok:true}, sin enviar ningún email (anti-enumeración)", async () => {
    const sendEmail = vi.fn().mockResolvedValue({ ok: true });
    const result = await attemptOtpRequest(
      { document_id: "DOC-NO-EXISTE", first_name: "Nadie", last_name: "Real", language: "es" },
      deps({ sendEmail })
    );

    expect(result).toEqual({ ok: true });
    expect(sendEmail).not.toHaveBeenCalled();
  });

  it("documento correcto pero nombre/apellido NO matchean -> MISMA respuesta {ok:true}, sin enviar email (anti-enumeración, segundo factor nunca se dispara sin el primero)", async () => {
    const sendEmail = vi.fn().mockResolvedValue({ ok: true });
    const result = await attemptOtpRequest(
      { document_id: MARIA_DOCUMENT, first_name: "Otro", last_name: "Nombre", language: "es" },
      deps({ sendEmail })
    );

    expect(result).toEqual({ ok: true });
    expect(sendEmail).not.toHaveBeenCalled();
  });

  it("document_id faltante -> invalid_request", async () => {
    const result = await attemptOtpRequest({ first_name: MARIA_FIRST_NAME, last_name: MARIA_LAST_NAME, language: "es" }, deps());
    expect(result).toEqual({ ok: false, reason: "invalid_request" });
  });

  it("first_name/last_name faltantes -> invalid_request (nunca llega a buscar en customers)", async () => {
    const sendEmail = vi.fn().mockResolvedValue({ ok: true });
    const result = await attemptOtpRequest({ document_id: MARIA_DOCUMENT, language: "es" }, deps({ sendEmail }));

    expect(result).toEqual({ ok: false, reason: "invalid_request" });
    expect(sendEmail).not.toHaveBeenCalled();
  });

  it("en cooldown (pedido hace <60s) -> {ok:true} pero NO reenvía el email", async () => {
    const store = new FakeOtpStore();
    const now = Date.now();
    store.setRaw(MARIA_DOCUMENT, {
      documentId: MARIA_DOCUMENT,
      codeHash: "irrelevante",
      expiresAt: Math.floor(now / 1000) + 600,
      attempts: 0,
      lastRequestedAt: now - 1000, // hace 1 segundo, dentro del cooldown de 60s
      customerId: "CUST-0001",
    });

    const sendEmail = vi.fn().mockResolvedValue({ ok: true });
    const result = await attemptOtpRequest(
      { document_id: MARIA_DOCUMENT, first_name: MARIA_FIRST_NAME, last_name: MARIA_LAST_NAME, language: "es" },
      deps({ store: store as unknown as Parameters<typeof attemptOtpRequest>[1]["store"], sendEmail, now: () => now })
    );

    expect(result).toEqual({ ok: true });
    expect(sendEmail).not.toHaveBeenCalled();
  });

  it("fuera del cooldown -> vuelve a enviar un código nuevo", async () => {
    const store = new FakeOtpStore();
    const now = Date.now();
    store.setRaw(MARIA_DOCUMENT, {
      documentId: MARIA_DOCUMENT,
      codeHash: "irrelevante",
      expiresAt: Math.floor(now / 1000) + 600,
      attempts: 0,
      lastRequestedAt: now - REQUEST_COOLDOWN_MS - 1000,
      customerId: "CUST-0001",
    });

    const sendEmail = vi.fn().mockResolvedValue({ ok: true });
    const result = await attemptOtpRequest(
      { document_id: MARIA_DOCUMENT, first_name: MARIA_FIRST_NAME, last_name: MARIA_LAST_NAME, language: "es" },
      deps({ store: store as unknown as Parameters<typeof attemptOtpRequest>[1]["store"], sendEmail, now: () => now })
    );

    expect(result).toEqual({ ok: true });
    expect(sendEmail).toHaveBeenCalledTimes(1);
  });

  it("falla el envío de email -> igual responde {ok:true} (nunca revela el fallo interno al usuario)", async () => {
    const sendEmail = vi.fn().mockResolvedValue({ ok: false });
    const result = await attemptOtpRequest(
      { document_id: MARIA_DOCUMENT, first_name: MARIA_FIRST_NAME, last_name: MARIA_LAST_NAME, language: "es" },
      deps({ sendEmail })
    );
    expect(result).toEqual({ ok: true });
  });
});
