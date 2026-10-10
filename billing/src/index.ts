import {
  deactivateCode,
  finalPriceCents,
  getCode,
  createCode,
  incrementRedemption,
  listCodes,
  normalizeCode,
  parseCreateCodeBody,
  validateCodeForPlan,
  type DiscountCode,
} from "./codes";
import { getEntitlement, normalizeEmail, writeEntitlement } from "./entitlements";
import { PLANS, PLAN_IDS, formatPrice, getPlan, isPlanId, type PlanId } from "./plans";
import { Router, type RouteContext } from "./router";
import { createCheckoutSession, verifyStripeSignature } from "./stripe";
import { HttpError, isRecord, type Env, type JsonObject } from "./types";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Max-Age": "86400",
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

function errorResponse(status: number, message: string): Response {
  return json({ error: message }, status);
}

async function readJsonBody(request: Request): Promise<JsonObject> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    throw new HttpError(400, "invalid JSON body");
  }
  if (!isRecord(body)) throw new HttpError(400, "body must be a JSON object");
  return body;
}

function requireAdmin(ctx: RouteContext): void {
  const header = ctx.request.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!ctx.env.ADMIN_TOKEN || token !== ctx.env.ADMIN_TOKEN) {
    throw new HttpError(401, "unauthorized");
  }
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// --- Public handlers ---------------------------------------------------------

function handlePlans(): Response {
  return json({
    plans: PLAN_IDS.map((id) => {
      const p = PLANS[id];
      return {
        id: p.id,
        name: p.name,
        amountCents: p.amountCents,
        displayPrice: p.interval ? `${formatPrice(p.amountCents)}/${p.interval}` : `${formatPrice(p.amountCents)} once`,
        currency: p.currency,
        interval: p.interval,
        mode: p.mode,
      };
    }),
  });
}

async function handleValidateCode(ctx: RouteContext): Promise<Response> {
  const body = await readJsonBody(ctx.request);
  if (typeof body.code !== "string" || body.code.trim().length === 0) throw new HttpError(400, "code is required");
  if (!isPlanId(body.plan)) throw new HttpError(400, `plan must be one of: ${PLAN_IDS.join(", ")}`);
  const plan: PlanId = body.plan;

  const record = await getCode(ctx.env.BILLING_KV, body.code);
  const result = validateCodeForPlan(record, plan);
  if (!result.valid || !result.code) {
    return json({ valid: false, reason: result.reason ?? "invalid code", finalPrice: getPlan(plan).amountCents });
  }
  const code = result.code;
  return json({
    valid: true,
    type: code.percentOff !== undefined ? "percent" : "amount",
    ...(code.percentOff !== undefined ? { percentOff: code.percentOff } : {}),
    ...(code.amountOffCents !== undefined ? { amountOff: code.amountOffCents } : {}),
    finalPrice: finalPriceCents(plan, code),
  });
}

async function handleCheckout(ctx: RouteContext): Promise<Response> {
  const body = await readJsonBody(ctx.request);
  if (!isPlanId(body.plan)) throw new HttpError(400, `plan must be one of: ${PLAN_IDS.join(", ")}`);
  const plan = getPlan(body.plan);

  let email: string | undefined;
  if (body.email !== undefined) {
    if (typeof body.email !== "string" || !EMAIL_RE.test(body.email)) throw new HttpError(400, "email is invalid");
    email = normalizeEmail(body.email);
  }

  let code: DiscountCode | undefined;
  if (body.code !== undefined) {
    if (typeof body.code !== "string" || body.code.trim().length === 0) throw new HttpError(400, "code must be a non-empty string");
    const record = await getCode(ctx.env.BILLING_KV, body.code);
    const result = validateCodeForPlan(record, plan.id);
    if (!result.valid || !result.code) throw new HttpError(400, result.reason ?? "invalid code");
    code = result.code;
  }

  const { url } = await createCheckoutSession(ctx.env, plan, { email, code });
  return json({ url });
}

async function handleLicense(ctx: RouteContext): Promise<Response> {
  const email = ctx.params.email;
  if (!EMAIL_RE.test(email)) throw new HttpError(400, "email is invalid");
  const ent = await getEntitlement(ctx.env.BILLING_KV, email);
  if (!ent || !ent.active) {
    return json({ active: false, ...(ent ? { plan: ent.plan, since: ent.since } : {}) });
  }
  return json({
    active: true,
    plan: ent.plan,
    since: ent.since,
    ...(ent.expires ? { expires: ent.expires } : {}),
  });
}

// --- Stripe webhook ----------------------------------------------------------

function stringField(obj: JsonObject, key: string): string | undefined {
  const v = obj[key];
  return typeof v === "string" ? v : undefined;
}

function recordField(obj: JsonObject, key: string): JsonObject {
  const v = obj[key];
  return isRecord(v) ? v : {};
}

async function handleWebhook(ctx: RouteContext): Promise<Response> {
  const payload = await ctx.request.text();
  const ok = await verifyStripeSignature(payload, ctx.request.headers.get("Stripe-Signature"), ctx.env.STRIPE_WEBHOOK_SECRET);
  if (!ok) return errorResponse(400, "invalid signature");

  let event: unknown;
  try {
    event = JSON.parse(payload);
  } catch {
    return errorResponse(400, "invalid JSON payload");
  }
  if (!isRecord(event) || typeof event.type !== "string" || !isRecord(event.data) || !isRecord(event.data.object)) {
    return errorResponse(400, "malformed event");
  }
  const object = event.data.object;
  const kv = ctx.env.BILLING_KV;

  switch (event.type) {
    case "checkout.session.completed": {
      const metadata = recordField(object, "metadata");
      const planId = stringField(metadata, "plan");
      const email =
        stringField(recordField(object, "customer_details"), "email") ??
        stringField(object, "customer_email") ??
        stringField(metadata, "email");
      if (email && planId && isPlanId(planId)) {
        await writeEntitlement(kv, email, {
          active: true,
          plan: planId,
          stripeCustomerId: stringField(object, "customer"),
          stripeSubscriptionId: stringField(object, "subscription"),
        });
      }
      const code = stringField(metadata, "code");
      if (code) await incrementRedemption(kv, normalizeCode(code));
      break;
    }
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const metadata = recordField(object, "metadata");
      const email = stringField(metadata, "email");
      const planId = stringField(metadata, "plan");
      if (email && planId && isPlanId(planId)) {
        const status = stringField(object, "status");
        const deleted = event.type === "customer.subscription.deleted";
        const active = !deleted && (status === "active" || status === "trialing");
        const periodEnd = object.current_period_end;
        await writeEntitlement(kv, email, {
          active,
          plan: planId,
          expires: typeof periodEnd === "number" ? new Date(periodEnd * 1000).toISOString() : undefined,
          stripeCustomerId: stringField(object, "customer"),
          stripeSubscriptionId: stringField(object, "id"),
        });
      }
      break;
    }
    default:
      break; // Unhandled event types are acknowledged.
  }
  return json({ received: true });
}

// --- Admin handlers ----------------------------------------------------------

async function handleAdminCreateCode(ctx: RouteContext): Promise<Response> {
  requireAdmin(ctx);
  const input = parseCreateCodeBody(await readJsonBody(ctx.request));
  const record = await createCode(ctx.env.BILLING_KV, input);
  return json(record, 201);
}

async function handleAdminListCodes(ctx: RouteContext): Promise<Response> {
  requireAdmin(ctx);
  return json({ codes: await listCodes(ctx.env.BILLING_KV) });
}

async function handleAdminGetCode(ctx: RouteContext): Promise<Response> {
  requireAdmin(ctx);
  const record = await getCode(ctx.env.BILLING_KV, ctx.params.code);
  if (!record) throw new HttpError(404, "code not found");
  return json(record);
}

async function handleAdminDeleteCode(ctx: RouteContext): Promise<Response> {
  requireAdmin(ctx);
  return json(await deactivateCode(ctx.env.BILLING_KV, ctx.params.code));
}

// --- Worker entrypoint -------------------------------------------------------

export const router = new Router()
  .get("/v1/plans", handlePlans)
  .post("/v1/checkout", handleCheckout)
  .post("/v1/codes/validate", handleValidateCode)
  .get("/v1/license/:email", handleLicense)
  .post("/v1/webhook/stripe", handleWebhook)
  .post("/v1/admin/codes", handleAdminCreateCode)
  .get("/v1/admin/codes", handleAdminListCodes)
  .get("/v1/admin/codes/:code", handleAdminGetCode)
  .delete("/v1/admin/codes/:code", handleAdminDeleteCode);

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  try {
    const response = await router.handle(request, env);
    return response ?? errorResponse(404, "not found");
  } catch (err) {
    if (err instanceof HttpError) return errorResponse(err.status, err.message);
    console.error("unhandled error", err);
    return errorResponse(500, "internal error");
  }
}

export default {
  fetch: (request: Request, env: Env): Promise<Response> => handleRequest(request, env),
} satisfies ExportedHandler<Env>;
