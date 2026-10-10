# Session Watch billing

Cloudflare Worker: Stripe subscriptions + lifetime purchases, discount codes, and license lookups for Session Watch. Storage is Cloudflare KV (`BILLING_KV`); Stripe is called over raw REST (no SDK).

## Plans

| id | price | Stripe mode | price env var |
|---|---|---|---|
| `pro_monthly` | $4.99/month | subscription | `PRICE_PRO_MONTHLY` |
| `pro_yearly` | $39/year | subscription | `PRICE_PRO_YEARLY` |
| `lifetime` | $99 once | payment | `PRICE_LIFETIME` |

## Endpoints

Public (CORS `*`, JSON):

- `GET /v1/plans` → `{plans: [{id, name, amountCents, displayPrice, currency, interval, mode}]}`
- `POST /v1/checkout` — body `{plan, code?, email?}` → `{url}` (Stripe Checkout URL). Invalid code → 400 with reason. Success/cancel URLs: `${SITE_ORIGIN}/thanks` / `${SITE_ORIGIN}/pricing`.
- `POST /v1/codes/validate` — body `{code, plan}` → `{valid, type: "percent"|"amount", percentOff?|amountOff?, finalPrice}` or `{valid: false, reason, finalPrice}`. Does not redeem.
- `GET /v1/license/:email` → `{active, plan?, since?, expires?}` (written by the webhook).
- `POST /v1/webhook/stripe` — Stripe webhook. Verifies `Stripe-Signature` (HMAC-SHA256, 300s tolerance). Handles `checkout.session.completed` (grants entitlement, increments code redemptions), `customer.subscription.updated` / `.deleted` (updates `active` + `expires`).

Admin (`Authorization: Bearer $ADMIN_TOKEN`):

- `POST /v1/admin/codes` — `{code?, percentOff?|amountOffCents?, plans?, maxRedemptions?, expiresAt?, note?}`. Exactly one of `percentOff` (integer 1-100) or `amountOffCents`. Omit `code` to generate a readable 8-char code. → 201 with the full record.
- `GET /v1/admin/codes` — all codes with redemption counts.
- `GET /v1/admin/codes/:code` — detail (case-insensitive).
- `DELETE /v1/admin/codes/:code` — soft delete (sets `active: false`).

## Setup

1. Create the KV namespace and put its id in `wrangler.toml`:

   ```sh
   wrangler kv namespace create BILLING_KV
   ```

2. Create Stripe prices (Dashboard → Products, or CLI):

   ```sh
   stripe prices create --unit-amount 499 --currency usd -d "recurring[interval]=month" --product-data name="Session Watch Pro"
   stripe prices create --unit-amount 3900 --currency usd -d "recurring[interval]=year" --product-data name="Session Watch Pro"
   stripe prices create --unit-amount 9900 --currency usd --product-data name="Session Watch Lifetime"
   ```

   Put the resulting `price_...` ids in `[vars]` in `wrangler.toml` (`PRICE_PRO_MONTHLY`, `PRICE_PRO_YEARLY`, `PRICE_LIFETIME`) or set them as secrets. Missing ids fall back to obvious `price_PLACEHOLDER_*` values that Stripe rejects.

3. Secrets:

   ```sh
   wrangler secret put STRIPE_SECRET_KEY      # sk_live_... / sk_test_...
   wrangler secret put STRIPE_WEBHOOK_SECRET  # whsec_... from the webhook endpoint
   wrangler secret put ADMIN_TOKEN            # any long random string
   ```

4. In Stripe, add a webhook endpoint for `https://billing.sessionwatch.lajward.co/v1/webhook/stripe` with events `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`.

## Deploy

```sh
npm install
npm test
npm run deploy
```

## Example: create a discount code

```sh
curl -X POST https://billing.sessionwatch.lajward.co/v1/admin/codes \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"code":"LAUNCH50","percentOff":50,"plans":["pro_yearly","lifetime"],"maxRedemptions":100,"expiresAt":"2026-12-31T23:59:59Z","note":"launch promo"}'
```

Validate from the website:

```sh
curl -X POST https://billing.sessionwatch.lajward.co/v1/codes/validate \
  -H "Content-Type: application/json" \
  -d '{"code":"LAUNCH50","plan":"pro_yearly"}'
```
