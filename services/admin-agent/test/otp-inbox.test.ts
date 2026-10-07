import { describe, expect, it, vi } from "vitest";
import { getOtpInbox, isValidOtpInboxEmail, OTP_INBOX_NO_OVERRIDE, setOtpInbox } from "../src/otp-inbox";

const PARAM = "/banking-agent-dev/otp/inbox_override";

describe("isValidOtpInboxEmail", () => {
  it.each(["juez@example.com", "a.b+c@sub.dominio.lat"])("acepta %s", (email) => {
    expect(isValidOtpInboxEmail(email)).toBe(true);
  });

  it.each([undefined, null, 42, "", "sin-arroba", "con espacio@x.com", "a@b", "a@b.c d", "x".repeat(250) + "@a.com"])(
    "rechaza %s",
    (value) => {
      expect(isValidOtpInboxEmail(value)).toBe(false);
    }
  );
});

describe("getOtpInbox", () => {
  it("devuelve null cuando el parámetro está en el valor sentinel 'none'", async () => {
    const ssmClient = { send: vi.fn().mockResolvedValue({ Parameter: { Value: OTP_INBOX_NO_OVERRIDE } }) };
    expect(await getOtpInbox({ paramName: PARAM, ssmClient })).toBeNull();
  });

  it("devuelve el email fijado", async () => {
    const ssmClient = { send: vi.fn().mockResolvedValue({ Parameter: { Value: "juez@example.com" } }) };
    expect(await getOtpInbox({ paramName: PARAM, ssmClient })).toBe("juez@example.com");
  });
});

describe("setOtpInbox", () => {
  it("escribe el email en el parámetro SSM con Overwrite", async () => {
    const ssmClient = { send: vi.fn().mockResolvedValue({}) };
    await setOtpInbox("juez@example.com", { paramName: PARAM, ssmClient });

    expect(ssmClient.send).toHaveBeenCalledTimes(1);
    const command = ssmClient.send.mock.calls[0][0];
    expect(command.input).toEqual({ Name: PARAM, Type: "String", Value: "juez@example.com", Overwrite: true });
  });
});
