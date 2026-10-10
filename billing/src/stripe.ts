import type { DiscountCode } from "./codes";
import { getStripePriceId, type Plan } from "./plans";
import { HttpError, isRecord, type Env, type JsonObject } from "./types";

const STRIPE_API = "https://api.stripe.com";

/** Flat form-encoded params, e.g. { "line_items[0][price]": "price_x" }. */
export type StripeParams = Record<string, string>;

export function formEncode(params: StripeParams): string {
  const body = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) body.append(key, value);
  return body.toString();
}

async function stripePost(env: Env, path: string, params: StripeParams): Promise<JsonObject> {
  const res = await fetch(`${STRIPE_API}${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: formEncode(params),
  });
  const data: unknown = await res.json();
  if (!res.ok) {
    let message = `Stripe error (${res.status})`;
    if (isRecord(data) && isRecord(data.error) && typeof data.error.message === "string") {
      message = data.error.message;
    }
    throw new HttpError(502, message);
  }
  if (!isRecord(data)) throw new HttpError(502, "unexpected Stripe response");
  return data;
}

/** Ad-hoc one-off coupon mirroring a local discount code. */
async function createCoupon(env: Env, plan: Plan, code: DiscountCode): Promise<string> {
  const params: StripeParams = {
    duration: "once",
    name: `Code ${code.code}`,
    "metadata[code]": code.code,
  };
  if (code.percentOff !== undefined) {
    params.percent_off = String(code.percentOff);
  } else if (code.amountOffCents !== undefined) {
    // Stripe rejects amount_off greater than the total; clamp to the plan price.
    params.amount_off = String(Math.min(code.amountOffCents, plan.amountCents));
    params.currency = plan.currency;
  }
  const coupon = await stripePost(env, "/v1/coupons", params);
  if (typeof coupon.id !== "string") throw new HttpError(502, "Stripe coupon creation failed");
  return coupon.id;
}

export interface CheckoutResult {
  url: string;
}

export async function createCheckoutSession(
  env: Env,
  plan: Plan,
  options: { email?: string; code?: DiscountCode },
): Promise<CheckoutResult> {
  const site = env.SITE_ORIGIN ?? "https://sessionwatch.lajward.co";
  const params: StripeParams = {
    mode: plan.mode,
    "line_items[0][price]": getStripePriceId(env, plan),
    "line_items[0][quantity]": "1",
    success_url: `${site}/thanks?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${site}/pricing`,
    "metadata[plan]": plan.id,
  };
  if (options.email) {
    params.customer_email = options.email;
    params["metadata[email]"] = options.email;
  }
  if (options.code) {
    params["metadata[code]"] = options.code.code;
    const couponId = await createCoupon(env, plan, options.code);
    params["discounts[0][coupon]"] = couponId;
  }
  if (plan.mode === "subscription") {
    // Mirror metadata onto the subscription so later webhook events carry it.
    params["subscription_data[metadata][plan]"] = plan.id;
    if (options.email) params["subscription_data[metadata][email]"] = options.email;
  }

  const session = await stripePost(env, "/v1/checkout/sessions", params);
  if (typeof session.url !== "string") throw new HttpError(502, "Stripe did not return a checkout URL");
  return { url: session.url };
}

// --- Webhook signature verification -----------------------------------------

const encoder = new TextEncoder();

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export const WEBHOOK_TOLERANCE_SECONDS = 300;

/**
 * Verifies a Stripe-Signature header (t=...,v1=...) against the raw payload.
 * HMAC-SHA256 over `${t}.${payload}` with the webhook secret, plus a timestamp
 * tolerance check against replay.
 */
export async function verifyStripeSignature(
  payload: string,
  signatureHeader: string | null,
  secret: string,
  nowSeconds: number = Math.floor(Date.now() / 1000),
  toleranceSeconds: number = WEBHOOK_TOLERANCE_SECONDS,
): Promise<boolean> {
  if (!signatureHeader) return false;

  let timestamp: number | null = null;
  const candidates: string[] = [];
  for (const part of signatureHeader.split(",")) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    const key = part.slice(0, eq).trim();
    const value = part.slice(eq + 1).trim();
    if (key === "t") timestamp = Number(value);
    else if (key === "v1") candidates.push(value);
  }
  if (timestamp === null || !Number.isFinite(timestamp) || candidates.length === 0) return false;
  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${payload}`));
  const expected = toHex(mac);
  return candidates.some((candidate) => timingSafeEqualHex(candidate, expected));
}
