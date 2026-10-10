import type { Env } from "../src/types";

/** In-memory KV implementing the subset of KVNamespace the worker uses. */
export class MemoryKV {
  store = new Map<string, string>();

  async get(key: string, type?: string): Promise<unknown> {
    const value = this.store.get(key);
    if (value === undefined) return null;
    return type === "json" ? JSON.parse(value) : value;
  }

  async put(key: string, value: string): Promise<void> {
    this.store.set(key, value);
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }

  async list(options?: { prefix?: string; cursor?: string }): Promise<{
    keys: { name: string }[];
    list_complete: boolean;
    cursor?: string;
  }> {
    const prefix = options?.prefix ?? "";
    const keys = [...this.store.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name }));
    return { keys, list_complete: true };
  }
}

export function makeEnv(kv: MemoryKV): Env {
  return {
    BILLING_KV: kv as unknown as KVNamespace,
    STRIPE_SECRET_KEY: "sk_test_fake",
    STRIPE_WEBHOOK_SECRET: "whsec_test_secret",
    ADMIN_TOKEN: "admin-test-token",
    SITE_ORIGIN: "https://sessionwatch.lajward.co",
    PRICE_PRO_MONTHLY: "price_monthly_test",
    PRICE_PRO_YEARLY: "price_yearly_test",
    PRICE_LIFETIME: "price_lifetime_test",
  };
}

export function jsonRequest(method: string, path: string, body?: unknown, headers?: Record<string, string>): Request {
  return new Request(`https://billing.test${path}`, {
    method,
    headers: { "Content-Type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

export function adminHeaders(): Record<string, string> {
  return { Authorization: "Bearer admin-test-token" };
}

/** Builds a valid Stripe-Signature header for a payload. */
export async function signPayload(payload: string, secret: string, timestamp: number): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${payload}`));
  const hex = Array.from(new Uint8Array(mac), (b) => b.toString(16).padStart(2, "0")).join("");
  return `t=${timestamp},v1=${hex}`;
}
