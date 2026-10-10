import { describe, expect, it } from "vitest";
import {
  createCode,
  finalPriceCents,
  generateCode,
  getCode,
  parseCreateCodeBody,
  validateCodeForPlan,
  type DiscountCode,
} from "../src/codes";
import { handleRequest } from "../src/index";
import { HttpError } from "../src/types";
import { MemoryKV, adminHeaders, jsonRequest, makeEnv } from "./helpers";

function baseCode(overrides: Partial<DiscountCode> = {}): DiscountCode {
  return {
    code: "TESTCODE",
    percentOff: 50,
    active: true,
    createdAt: new Date().toISOString(),
    redemptions: 0,
    ...overrides,
  };
}

describe("parseCreateCodeBody", () => {
  it("requires exactly one of percentOff or amountOffCents", () => {
    expect(() => parseCreateCodeBody({})).toThrow(HttpError);
    expect(() => parseCreateCodeBody({ percentOff: 10, amountOffCents: 100 })).toThrow(/exactly one/);
  });

  it("rejects out-of-range percentOff", () => {
    expect(() => parseCreateCodeBody({ percentOff: 0 })).toThrow(/between 1 and 100/);
    expect(() => parseCreateCodeBody({ percentOff: 101 })).toThrow(/between 1 and 100/);
    expect(() => parseCreateCodeBody({ percentOff: 10.5 })).toThrow(/between 1 and 100/);
  });

  it("rejects past expiry", () => {
    expect(() => parseCreateCodeBody({ percentOff: 10, expiresAt: "2020-01-01T00:00:00Z" })).toThrow(/future/);
  });

  it("rejects unknown plans", () => {
    expect(() => parseCreateCodeBody({ percentOff: 10, plans: ["gold"] })).toThrow(/valid plan ids/);
  });

  it("uppercases provided codes", () => {
    expect(parseCreateCodeBody({ code: "launch50", percentOff: 50 }).code).toBe("LAUNCH50");
  });
});

describe("generateCode", () => {
  it("makes 8-char codes without ambiguous characters", () => {
    for (let i = 0; i < 50; i++) {
      const code = generateCode();
      expect(code).toMatch(/^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/);
    }
  });
});

describe("createCode", () => {
  it("stores and retrieves codes case-insensitively", async () => {
    const kv = new MemoryKV();
    await createCode(kv as unknown as KVNamespace, { code: "HALFOFF", percentOff: 50 });
    const record = await getCode(kv as unknown as KVNamespace, "halfoff");
    expect(record?.code).toBe("HALFOFF");
    expect(record?.active).toBe(true);
    expect(record?.redemptions).toBe(0);
  });

  it("rejects duplicates", async () => {
    const kv = new MemoryKV();
    await createCode(kv as unknown as KVNamespace, { code: "DUP", percentOff: 10 });
    await expect(createCode(kv as unknown as KVNamespace, { code: "DUP", percentOff: 20 })).rejects.toThrow(/exists/);
  });
});

describe("validateCodeForPlan", () => {
  it("rejects missing or inactive codes", () => {
    expect(validateCodeForPlan(null, "pro_monthly").valid).toBe(false);
    expect(validateCodeForPlan(baseCode({ active: false }), "pro_monthly").reason).toMatch(/inactive/);
  });

  it("rejects expired codes", () => {
    const expired = baseCode({ expiresAt: new Date(Date.now() - 1000).toISOString() });
    expect(validateCodeForPlan(expired, "pro_monthly").reason).toMatch(/expired/);
    const fresh = baseCode({ expiresAt: new Date(Date.now() + 60_000).toISOString() });
    expect(validateCodeForPlan(fresh, "pro_monthly").valid).toBe(true);
  });

  it("rejects codes at the redemption limit", () => {
    const maxed = baseCode({ maxRedemptions: 3, redemptions: 3 });
    expect(validateCodeForPlan(maxed, "pro_monthly").reason).toMatch(/limit/);
    const underLimit = baseCode({ maxRedemptions: 3, redemptions: 2 });
    expect(validateCodeForPlan(underLimit, "pro_monthly").valid).toBe(true);
  });

  it("enforces plan restrictions", () => {
    const restricted = baseCode({ plans: ["lifetime"] });
    expect(validateCodeForPlan(restricted, "pro_monthly").reason).toMatch(/not valid for plan/);
    expect(validateCodeForPlan(restricted, "lifetime").valid).toBe(true);
  });
});

describe("finalPriceCents", () => {
  it("computes percent discounts", () => {
    expect(finalPriceCents("pro_monthly", baseCode({ percentOff: 50 }))).toBe(249); // 499 - round(249.5)
    expect(finalPriceCents("pro_yearly", baseCode({ percentOff: 100 }))).toBe(0);
    expect(finalPriceCents("lifetime", baseCode({ percentOff: 10 }))).toBe(8910);
  });

  it("computes amount discounts and clamps at zero", () => {
    expect(finalPriceCents("pro_monthly", baseCode({ percentOff: undefined, amountOffCents: 100 }))).toBe(399);
    expect(finalPriceCents("pro_monthly", baseCode({ percentOff: undefined, amountOffCents: 10_000 }))).toBe(0);
  });
});

describe("admin endpoints", () => {
  it("requires the admin token", async () => {
    const env = makeEnv(new MemoryKV());
    const res = await handleRequest(jsonRequest("POST", "/v1/admin/codes", { percentOff: 10 }), env);
    expect(res.status).toBe(401);
    const bad = await handleRequest(
      jsonRequest("POST", "/v1/admin/codes", { percentOff: 10 }, { Authorization: "Bearer wrong" }),
      env,
    );
    expect(bad.status).toBe(401);
  });

  it("creates, lists, reads and deactivates codes", async () => {
    const env = makeEnv(new MemoryKV());
    const create = await handleRequest(
      jsonRequest("POST", "/v1/admin/codes", { code: "LAUNCH", percentOff: 20, maxRedemptions: 5 }, adminHeaders()),
      env,
    );
    expect(create.status).toBe(201);
    const created = (await create.json()) as DiscountCode;
    expect(created.code).toBe("LAUNCH");

    const generated = await handleRequest(
      jsonRequest("POST", "/v1/admin/codes", { amountOffCents: 500 }, adminHeaders()),
      env,
    );
    expect(generated.status).toBe(201);
    expect(((await generated.json()) as DiscountCode).code).toMatch(/^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/);

    const list = await handleRequest(jsonRequest("GET", "/v1/admin/codes", undefined, adminHeaders()), env);
    expect(((await list.json()) as { codes: DiscountCode[] }).codes).toHaveLength(2);

    const detail = await handleRequest(jsonRequest("GET", "/v1/admin/codes/launch", undefined, adminHeaders()), env);
    expect(detail.status).toBe(200);

    const del = await handleRequest(jsonRequest("DELETE", "/v1/admin/codes/LAUNCH", undefined, adminHeaders()), env);
    expect(((await del.json()) as DiscountCode).active).toBe(false);

    const validate = await handleRequest(
      jsonRequest("POST", "/v1/codes/validate", { code: "LAUNCH", plan: "pro_monthly" }),
      env,
    );
    expect(((await validate.json()) as { valid: boolean }).valid).toBe(false);
  });
});

describe("POST /v1/codes/validate", () => {
  it("returns discount details and final price", async () => {
    const kv = new MemoryKV();
    const env = makeEnv(kv);
    await createCode(kv as unknown as KVNamespace, { code: "HALF", percentOff: 50, plans: ["pro_yearly"] });

    const ok = await handleRequest(jsonRequest("POST", "/v1/codes/validate", { code: "half", plan: "pro_yearly" }), env);
    expect(await ok.json()).toEqual({ valid: true, type: "percent", percentOff: 50, finalPrice: 1950 });

    const wrongPlan = await handleRequest(
      jsonRequest("POST", "/v1/codes/validate", { code: "HALF", plan: "pro_monthly" }),
      env,
    );
    const body = (await wrongPlan.json()) as { valid: boolean; reason: string; finalPrice: number };
    expect(body.valid).toBe(false);
    expect(body.finalPrice).toBe(499);
  });

  it("400s on bad input", async () => {
    const env = makeEnv(new MemoryKV());
    expect((await handleRequest(jsonRequest("POST", "/v1/codes/validate", { plan: "pro_monthly" }), env)).status).toBe(400);
    expect((await handleRequest(jsonRequest("POST", "/v1/codes/validate", { code: "X", plan: "nope" }), env)).status).toBe(400);
  });
});
