import { afterEach, describe, expect, it, vi } from "vitest";

// config.js reads the environment once at import, so each case imports it fresh.
async function loadConfig(env) {
  vi.resetModules();
  for (const [k, v] of Object.entries(env)) vi.stubEnv(k, v);
  return (await import("../server/config.js")).config;
}

afterEach(() => vi.unstubAllEnvs());

describe("config", () => {
  it("serves at PUBLIC_HOST when set", async () => {
    const config = await loadConfig({ APP_NAME: "app", PUBLIC_HOST: "web.billandjessie.com" });
    expect(config.publicHost).toBe("web.billandjessie.com");
  });

  it("defaults the host to <app>.billandjessie.com", async () => {
    const config = await loadConfig({ APP_NAME: "app", PUBLIC_HOST: "" });
    expect(config.publicHost).toBe("app.billandjessie.com");
  });

  it("derives the session secret from the client secret, never the dev default", async () => {
    const a = await loadConfig({ SESSION_SECRET: "", AUTHENTIK_CLIENT_SECRET: "one" });
    const b = await loadConfig({ SESSION_SECRET: "", AUTHENTIK_CLIENT_SECRET: "two" });
    expect(a.sessionSecret).toMatch(/^[0-9a-f]{64}$/);
    expect(a.sessionSecret).not.toBe(b.sessionSecret);
    expect(a.sessionSecret).not.toContain("one");
  });

  it("uses Authentik's issuer exactly, trailing slash included", async () => {
    const config = await loadConfig({ APP_NAME: "app", AUTHENTIK_BASE_URL: "" });
    expect(config.issuerUrl).toBe("https://auth.billandjessie.com/application/o/app/");
  });

  it("prefers SESSION_SECRET", async () => {
    const config = await loadConfig({ SESSION_SECRET: "set", AUTHENTIK_CLIENT_SECRET: "one" });
    expect(config.sessionSecret).toBe("set");
  });
});
