import { getPlan, isPlanId, type PlanId } from "./plans";
import { HttpError, isRecord } from "./types";

export interface DiscountCode {
  /** Stored uppercase; lookups are case-insensitive. */
  code: string;
  percentOff?: number;
  amountOffCents?: number;
  /** Plans the code applies to; undefined = all plans. */
  plans?: PlanId[];
  maxRedemptions?: number;
  /** ISO 8601 timestamp. */
  expiresAt?: string;
  note?: string;
  active: boolean;
  createdAt: string;
  redemptions: number;
}

export interface CodeValidation {
  valid: boolean;
  reason?: string;
  code?: DiscountCode;
}

const CODE_KEY_PREFIX = "code:";
/** Readable alphabet: no 0/O, 1/I/L, or vowels that spell words accidentally. */
const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";

export function normalizeCode(code: string): string {
  return code.trim().toUpperCase();
}

function codeKey(code: string): string {
  return CODE_KEY_PREFIX + normalizeCode(code);
}

export function generateCode(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  let out = "";
  for (const b of bytes) out += CODE_ALPHABET[b % CODE_ALPHABET.length];
  return out;
}

export interface CreateCodeInput {
  code?: string;
  percentOff?: number;
  amountOffCents?: number;
  plans?: PlanId[];
  maxRedemptions?: number;
  expiresAt?: string;
  note?: string;
}

export function parseCreateCodeBody(body: unknown): CreateCodeInput {
  if (!isRecord(body)) throw new HttpError(400, "body must be a JSON object");
  const input: CreateCodeInput = {};

  if (body.code !== undefined) {
    if (typeof body.code !== "string" || !/^[A-Za-z0-9_-]{3,32}$/.test(body.code.trim())) {
      throw new HttpError(400, "code must be 3-32 characters (letters, digits, - or _)");
    }
    input.code = normalizeCode(body.code);
  }

  const hasPercent = body.percentOff !== undefined;
  const hasAmount = body.amountOffCents !== undefined;
  if (hasPercent === hasAmount) {
    throw new HttpError(400, "exactly one of percentOff or amountOffCents is required");
  }
  if (hasPercent) {
    if (typeof body.percentOff !== "number" || !Number.isInteger(body.percentOff) || body.percentOff < 1 || body.percentOff > 100) {
      throw new HttpError(400, "percentOff must be an integer between 1 and 100");
    }
    input.percentOff = body.percentOff;
  }
  if (hasAmount) {
    if (typeof body.amountOffCents !== "number" || !Number.isInteger(body.amountOffCents) || body.amountOffCents < 1) {
      throw new HttpError(400, "amountOffCents must be a positive integer");
    }
    input.amountOffCents = body.amountOffCents;
  }

  if (body.plans !== undefined) {
    if (!Array.isArray(body.plans) || body.plans.length === 0 || !body.plans.every(isPlanId)) {
      throw new HttpError(400, "plans must be a non-empty array of valid plan ids");
    }
    input.plans = body.plans;
  }

  if (body.maxRedemptions !== undefined) {
    if (typeof body.maxRedemptions !== "number" || !Number.isInteger(body.maxRedemptions) || body.maxRedemptions < 1) {
      throw new HttpError(400, "maxRedemptions must be a positive integer");
    }
    input.maxRedemptions = body.maxRedemptions;
  }

  if (body.expiresAt !== undefined) {
    if (typeof body.expiresAt !== "string" || Number.isNaN(Date.parse(body.expiresAt))) {
      throw new HttpError(400, "expiresAt must be an ISO 8601 timestamp");
    }
    if (Date.parse(body.expiresAt) <= Date.now()) {
      throw new HttpError(400, "expiresAt must be in the future");
    }
    input.expiresAt = body.expiresAt;
  }

  if (body.note !== undefined) {
    if (typeof body.note !== "string" || body.note.length > 500) {
      throw new HttpError(400, "note must be a string of at most 500 characters");
    }
    input.note = body.note;
  }

  return input;
}

export async function getCode(kv: KVNamespace, code: string): Promise<DiscountCode | null> {
  return kv.get<DiscountCode>(codeKey(code), "json");
}

async function putCode(kv: KVNamespace, record: DiscountCode): Promise<void> {
  await kv.put(codeKey(record.code), JSON.stringify(record));
}

export async function createCode(kv: KVNamespace, input: CreateCodeInput): Promise<DiscountCode> {
  let code = input.code;
  if (code) {
    if (await getCode(kv, code)) throw new HttpError(409, `code ${code} already exists`);
  } else {
    // Generated codes are collision-checked a few times before giving up.
    for (let i = 0; i < 5 && !code; i++) {
      const candidate = generateCode();
      if (!(await getCode(kv, candidate))) code = candidate;
    }
    if (!code) throw new HttpError(500, "could not generate a unique code");
  }

  const record: DiscountCode = {
    code,
    ...(input.percentOff !== undefined ? { percentOff: input.percentOff } : {}),
    ...(input.amountOffCents !== undefined ? { amountOffCents: input.amountOffCents } : {}),
    ...(input.plans ? { plans: input.plans } : {}),
    ...(input.maxRedemptions !== undefined ? { maxRedemptions: input.maxRedemptions } : {}),
    ...(input.expiresAt ? { expiresAt: input.expiresAt } : {}),
    ...(input.note !== undefined ? { note: input.note } : {}),
    active: true,
    createdAt: new Date().toISOString(),
    redemptions: 0,
  };
  await putCode(kv, record);
  return record;
}

export async function listCodes(kv: KVNamespace): Promise<DiscountCode[]> {
  const codes: DiscountCode[] = [];
  let cursor: string | undefined;
  do {
    const page = await kv.list({ prefix: CODE_KEY_PREFIX, cursor });
    for (const key of page.keys) {
      const record = await kv.get<DiscountCode>(key.name, "json");
      if (record) codes.push(record);
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return codes;
}

export async function deactivateCode(kv: KVNamespace, code: string): Promise<DiscountCode> {
  const record = await getCode(kv, code);
  if (!record) throw new HttpError(404, "code not found");
  record.active = false;
  await putCode(kv, record);
  return record;
}

export async function incrementRedemption(kv: KVNamespace, code: string): Promise<void> {
  const record = await getCode(kv, code);
  if (!record) return;
  record.redemptions += 1;
  await putCode(kv, record);
}

/** Shared validation used by /v1/codes/validate and /v1/checkout. Does not redeem. */
export function validateCodeForPlan(record: DiscountCode | null, plan: PlanId, now: number = Date.now()): CodeValidation {
  if (!record || !record.active) return { valid: false, reason: "code not found or inactive" };
  if (record.expiresAt && Date.parse(record.expiresAt) <= now) return { valid: false, reason: "code expired", code: record };
  if (record.maxRedemptions !== undefined && record.redemptions >= record.maxRedemptions) {
    return { valid: false, reason: "code redemption limit reached", code: record };
  }
  if (record.plans && !record.plans.includes(plan)) {
    return { valid: false, reason: `code not valid for plan ${plan}`, code: record };
  }
  return { valid: true, code: record };
}

/** Discounted price in cents for a plan, never below zero. */
export function finalPriceCents(planId: PlanId, record: DiscountCode): number {
  const base = getPlan(planId).amountCents;
  if (record.percentOff !== undefined) {
    return Math.max(0, base - Math.round((base * record.percentOff) / 100));
  }
  if (record.amountOffCents !== undefined) {
    return Math.max(0, base - record.amountOffCents);
  }
  return base;
}
