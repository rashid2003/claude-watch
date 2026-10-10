import { afterEach, describe, expect, it, vi } from "vitest";
import { createCode } from "../src/codes";
import { handleRequest } from "../src/index";
import { MemoryKV, jsonRequest, makeEnv } from "./helpers";

interface StripeCall {
  url: string;
  params: URLSearchParams;
  auth: string | null;
}

function mockStripe(): StripeCall[] {
  const calls: StripeCall[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      const url = String(input);
      const headers = new Headers(init?.headers);
      calls.push({ url, params: new URLSearchParams(String(init?.body)), auth: headers.get("Authorization") });
      if (url.endsWith("/v1/coupons")) {
        return Response.json({ id: "coupon_test_123" });
      }
      if (url.endsWith("/v1/checkout/sessions")) {
        return Response.json({ id: "cs_test_123", url: "https://checkout.stripe.com/c/pay/cs_test_123" });
      }
      return Response.json({ error: { message: "unexpected call" } }, { status: 400 });
    }),
  );
  return calls;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("POST /v1/checkout", () => {
  it("rejects bad plans, emails and invalid codes", async () => {
    const env = makeEnv(new MemoryKV());
    mockStripe();

    expect((await handleRequest(jsonRequest("POST", "/v1/checkout", { plan: "gold" }), env)).status).toBe(400);
    expect((await handleRequest(jsonRequest("POST", "/v1/checkout", {}), env)).status).toBe(400);
    expect(
      (await handleRequest(jsonRequest("POST", "/v1/checkout", { plan: "pro_monthly", email: "nope" }), env)).status,
    ).toBe(400);

    const badCode = await handleRequest(
      jsonRequest("POST", "/v1/checkout", { plan: "pro_monthly", code: "NOSUCH" }),
      env,
    );
    expect(badCode.status).toBe(400);
    expect(((await badCode.json()) as { error: string }).error).toMatch(/not found or inactive/);
  });

  it("creates a subscription-mode session for monthly plans", async () => {
    const env = makeEnv(new MemoryKV());
    const calls = mockStripe();

    const res = await handleRequest(
      jsonRequest("POST", "/v1/checkout", { plan: "pro_monthly", email: "a@b.co" }),
      env,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ url: "https://checkout.stripe.com/c/pay/cs_test_123" });

    expect(calls).toHaveLength(1);
    const p = calls[0].params;
    expect(calls[0].url).toBe("https://api.stripe.com/v1/checkout/sessions");
    expect(calls[0].auth).toBe("Bearer sk_test_fake");
    expect(p.get("mode")).toBe("subscription");
    expect(p.get("line_items[0][price]")).toBe("price_monthly_test");
    expect(p.get("customer_email")).toBe("a@b.co");
    expect(p.get("success_url")).toBe("https://sessionwatch.lajward.co/thanks?session_id={CHECKOUT_SESSION_ID}");
    expect(p.get("cancel_url")).toBe("https://sessionwatch.lajward.co/pricing");
    expect(p.get("subscription_data[metadata][plan]")).toBe("pro_monthly");
    expect(p.get("subscription_data[metadata][email]")).toBe("a@b.co");
  });

  it("creates a payment-mode session with a coupon for lifetime + code", async () => {
    const kv = new MemoryKV();
    const env = makeEnv(kv);
    await createCode(kv as unknown as KVNamespace, { code: "SAVE20", amountOffCents: 2000 });
    const calls = mockStripe();

    const res = await handleRequest(jsonRequest("POST", "/v1/checkout", { plan: "lifetime", code: "save20" }), env);
    expect(res.status).toBe(200);

    expect(calls).toHaveLength(2);
    const couponCall = calls[0];
    expect(couponCall.url).toBe("https://api.stripe.com/v1/coupons");
    expect(couponCall.params.get("amount_off")).toBe("2000");
    expect(couponCall.params.get("currency")).toBe("usd");

    const sessionCall = calls[1];
    const p = sessionCall.params;
    expect(p.get("mode")).toBe("payment");
    expect(p.get("line_items[0][price]")).toBe("price_lifetime_test");
    expect(p.get("discounts[0][coupon]")).toBe("coupon_test_123");
    expect(p.get("metadata[code]")).toBe("SAVE20");
    expect(p.get("metadata[plan]")).toBe("lifetime");
  });

  it("uses placeholder price ids when env vars are missing", async () => {
    const env = { ...makeEnv(new MemoryKV()), PRICE_LIFETIME: undefined };
    const calls = mockStripe();
    await handleRequest(jsonRequest("POST", "/v1/checkout", { plan: "lifetime" }), env);
    expect(calls[0].params.get("line_items[0][price]")).toBe("price_PLACEHOLDER_lifetime");
  });

  it("surfaces Stripe errors as 502", async () => {
    const env = makeEnv(new MemoryKV());
    vi.stubGlobal(
      "fetch",
      vi.fn(async (): Promise<Response> => Response.json({ error: { message: "No such price" } }, { status: 400 })),
    );
    const res = await handleRequest(jsonRequest("POST", "/v1/checkout", { plan: "pro_yearly" }), env);
    expect(res.status).toBe(502);
    expect(((await res.json()) as { error: string }).error).toBe("No such price");
  });
});

describe("GET /v1/plans", () => {
  it("lists plans with display prices", async () => {
    const env = makeEnv(new MemoryKV());
    const res = await handleRequest(jsonRequest("GET", "/v1/plans"), env);
    expect(res.status).toBe(200);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
    const body = (await res.json()) as { plans: { id: string; displayPrice: string }[] };
    expect(body.plans.map((p) => [p.id, p.displayPrice])).toEqual([
      ["pro_monthly", "$4.99/month"],
      ["pro_yearly", "$39/year"],
      ["lifetime", "$99 once"],
    ]);
  });
});
