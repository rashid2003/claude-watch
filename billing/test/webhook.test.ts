import { describe, expect, it } from "vitest";
import { createCode, getCode } from "../src/codes";
import { getEntitlement } from "../src/entitlements";
import { handleRequest } from "../src/index";
import { verifyStripeSignature } from "../src/stripe";
import { MemoryKV, makeEnv, signPayload } from "./helpers";

const SECRET = "whsec_test_secret";

function webhookRequest(payload: string, signature: string): Request {
  return new Request("https://billing.test/v1/webhook/stripe", {
    method: "POST",
    headers: { "Stripe-Signature": signature },
    body: payload,
  });
}

describe("verifyStripeSignature", () => {
  const payload = '{"id":"evt_1"}';

  it("accepts a valid signature within tolerance", async () => {
    const now = Math.floor(Date.now() / 1000);
    const header = await signPayload(payload, SECRET, now);
    expect(await verifyStripeSignature(payload, header, SECRET)).toBe(true);
  });

  it("rejects a tampered payload and wrong secret", async () => {
    const now = Math.floor(Date.now() / 1000);
    const header = await signPayload(payload, SECRET, now);
    expect(await verifyStripeSignature('{"id":"evt_2"}', header, SECRET)).toBe(false);
    expect(await verifyStripeSignature(payload, header, "whsec_other")).toBe(false);
  });

  it("rejects missing or malformed headers", async () => {
    expect(await verifyStripeSignature(payload, null, SECRET)).toBe(false);
    expect(await verifyStripeSignature(payload, "garbage", SECRET)).toBe(false);
    expect(await verifyStripeSignature(payload, "t=abc,v1=deadbeef", SECRET)).toBe(false);
  });

  it("rejects stale timestamps", async () => {
    const stale = Math.floor(Date.now() / 1000) - 600; // beyond 300s tolerance
    const header = await signPayload(payload, SECRET, stale);
    expect(await verifyStripeSignature(payload, header, SECRET)).toBe(false);
    // Same signature is fine when "now" is near the timestamp.
    expect(await verifyStripeSignature(payload, header, SECRET, stale + 10)).toBe(true);
  });
});

describe("POST /v1/webhook/stripe", () => {
  it("400s on a bad signature", async () => {
    const env = makeEnv(new MemoryKV());
    const res = await handleRequest(webhookRequest("{}", "t=1,v1=bad"), env);
    expect(res.status).toBe(400);
  });

  it("writes an entitlement and redeems the code on checkout.session.completed", async () => {
    const kv = new MemoryKV();
    const env = makeEnv(kv);
    await createCode(kv as unknown as KVNamespace, { code: "LAUNCH", percentOff: 20 });

    const payload = JSON.stringify({
      type: "checkout.session.completed",
      data: {
        object: {
          customer: "cus_123",
          subscription: "sub_123",
          customer_details: { email: "Buyer@Example.com" },
          metadata: { plan: "pro_monthly", code: "LAUNCH" },
        },
      },
    });
    const header = await signPayload(payload, SECRET, Math.floor(Date.now() / 1000));
    const res = await handleRequest(webhookRequest(payload, header), env);
    expect(res.status).toBe(200);

    const ent = await getEntitlement(kv as unknown as KVNamespace, "buyer@example.com");
    expect(ent).toMatchObject({
      email: "buyer@example.com",
      active: true,
      plan: "pro_monthly",
      stripeCustomerId: "cus_123",
      stripeSubscriptionId: "sub_123",
    });
    expect(ent?.since).toBeTruthy();

    const code = await getCode(kv as unknown as KVNamespace, "LAUNCH");
    expect(code?.redemptions).toBe(1);

    // License endpoint reflects it.
    const license = await handleRequest(
      new Request("https://billing.test/v1/license/buyer@example.com"),
      env,
    );
    const body = (await license.json()) as { active: boolean; plan: string };
    expect(body.active).toBe(true);
    expect(body.plan).toBe("pro_monthly");
  });

  it("updates expiry on customer.subscription.updated and deactivates on deleted", async () => {
    const kv = new MemoryKV();
    const env = makeEnv(kv);
    const periodEnd = Math.floor(Date.now() / 1000) + 30 * 86400;

    const updated = JSON.stringify({
      type: "customer.subscription.updated",
      data: {
        object: {
          id: "sub_123",
          customer: "cus_123",
          status: "active",
          current_period_end: periodEnd,
          metadata: { plan: "pro_yearly", email: "sub@example.com" },
        },
      },
    });
    let header = await signPayload(updated, SECRET, Math.floor(Date.now() / 1000));
    expect((await handleRequest(webhookRequest(updated, header), env)).status).toBe(200);

    let ent = await getEntitlement(kv as unknown as KVNamespace, "sub@example.com");
    expect(ent?.active).toBe(true);
    expect(ent?.expires).toBe(new Date(periodEnd * 1000).toISOString());

    const deleted = JSON.stringify({
      type: "customer.subscription.deleted",
      data: {
        object: {
          id: "sub_123",
          customer: "cus_123",
          status: "canceled",
          metadata: { plan: "pro_yearly", email: "sub@example.com" },
        },
      },
    });
    header = await signPayload(deleted, SECRET, Math.floor(Date.now() / 1000));
    expect((await handleRequest(webhookRequest(deleted, header), env)).status).toBe(200);

    ent = await getEntitlement(kv as unknown as KVNamespace, "sub@example.com");
    expect(ent?.active).toBe(false);

    const license = await handleRequest(new Request("https://billing.test/v1/license/sub@example.com"), env);
    expect(((await license.json()) as { active: boolean }).active).toBe(false);
  });

  it("acknowledges unhandled event types", async () => {
    const env = makeEnv(new MemoryKV());
    const payload = JSON.stringify({ type: "invoice.paid", data: { object: {} } });
    const header = await signPayload(payload, SECRET, Math.floor(Date.now() / 1000));
    const res = await handleRequest(webhookRequest(payload, header), env);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ received: true });
  });
});

describe("GET /v1/license/:email", () => {
  it("returns inactive for unknown emails and 400 for bad emails", async () => {
    const env = makeEnv(new MemoryKV());
    const unknown = await handleRequest(new Request("https://billing.test/v1/license/none@example.com"), env);
    expect(await unknown.json()).toEqual({ active: false });
    const bad = await handleRequest(new Request("https://billing.test/v1/license/not-an-email"), env);
    expect(bad.status).toBe(400);
  });
});
