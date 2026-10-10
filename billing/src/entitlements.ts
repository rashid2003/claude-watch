import type { PlanId } from "./plans";

export interface Entitlement {
  email: string;
  active: boolean;
  plan: PlanId;
  /** ISO 8601 — when the entitlement was first granted. */
  since: string;
  /** ISO 8601 — end of the current paid period; absent for lifetime. */
  expires?: string;
  stripeCustomerId?: string;
  stripeSubscriptionId?: string;
  updatedAt: string;
}

const ENT_KEY_PREFIX = "ent:";

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

function entKey(email: string): string {
  return ENT_KEY_PREFIX + normalizeEmail(email);
}

export async function getEntitlement(kv: KVNamespace, email: string): Promise<Entitlement | null> {
  return kv.get<Entitlement>(entKey(email), "json");
}

export interface EntitlementUpdate {
  active: boolean;
  plan: PlanId;
  expires?: string;
  stripeCustomerId?: string;
  stripeSubscriptionId?: string;
}

/** Creates or updates an entitlement, preserving the original `since`. */
export async function writeEntitlement(kv: KVNamespace, email: string, update: EntitlementUpdate): Promise<Entitlement> {
  const now = new Date().toISOString();
  const existing = await getEntitlement(kv, email);
  const record: Entitlement = {
    email: normalizeEmail(email),
    active: update.active,
    plan: update.plan,
    since: existing?.since ?? now,
    ...(update.expires ? { expires: update.expires } : {}),
    ...(update.stripeCustomerId ? { stripeCustomerId: update.stripeCustomerId } : {}),
    ...(update.stripeSubscriptionId ? { stripeSubscriptionId: update.stripeSubscriptionId } : {}),
    updatedAt: now,
  };
  await kv.put(entKey(email), JSON.stringify(record));
  return record;
}
