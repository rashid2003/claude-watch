import type { Env } from "./types";

export type PlanId = "pro_monthly" | "pro_yearly" | "lifetime";

export interface Plan {
  id: PlanId;
  name: string;
  amountCents: number;
  currency: "usd";
  /** Billing interval; null for one-time purchases. */
  interval: "month" | "year" | null;
  /** Stripe Checkout mode. */
  mode: "subscription" | "payment";
  /** Env var that holds the Stripe Price ID. */
  priceEnvKey: "PRICE_PRO_MONTHLY" | "PRICE_PRO_YEARLY" | "PRICE_LIFETIME";
}

export const PLANS: Record<PlanId, Plan> = {
  pro_monthly: {
    id: "pro_monthly",
    name: "Pro Monthly",
    amountCents: 499,
    currency: "usd",
    interval: "month",
    mode: "subscription",
    priceEnvKey: "PRICE_PRO_MONTHLY",
  },
  pro_yearly: {
    id: "pro_yearly",
    name: "Pro Yearly",
    amountCents: 3900,
    currency: "usd",
    interval: "year",
    mode: "subscription",
    priceEnvKey: "PRICE_PRO_YEARLY",
  },
  lifetime: {
    id: "lifetime",
    name: "Lifetime",
    amountCents: 9900,
    currency: "usd",
    interval: null,
    mode: "payment",
    priceEnvKey: "PRICE_LIFETIME",
  },
};

export const PLAN_IDS = Object.keys(PLANS) as PlanId[];

export function isPlanId(value: unknown): value is PlanId {
  return typeof value === "string" && value in PLANS;
}

export function getPlan(id: PlanId): Plan {
  return PLANS[id];
}

/**
 * Stripe Price ID for a plan. Falls back to an obvious placeholder so dev
 * environments fail loudly at Stripe rather than silently.
 */
export function getStripePriceId(env: Env, plan: Plan): string {
  const configured = env[plan.priceEnvKey];
  if (configured && configured.length > 0) return configured;
  return `price_PLACEHOLDER_${plan.id}`;
}

export function formatPrice(amountCents: number): string {
  const dollars = amountCents / 100;
  return `$${Number.isInteger(dollars) ? dollars.toFixed(0) : dollars.toFixed(2)}`;
}
