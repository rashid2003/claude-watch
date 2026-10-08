# Session Watch relay

A Cloudflare Worker that lets the iPhone app reach the Mac without Tailscale. Both apps dial out to it, and it pairs them up. Design: [`docs/specs/2026-10-02-relay-design.md`](../docs/specs/2026-10-02-relay-design.md).

The relay is a dumb pipe:

- Every stream is end-to-end encrypted by the apps (X25519 + ChaCha20-Poly1305). The key is pinned through the pairing QR.
- The Worker sees only ciphertext, a random room id per Mac, and a hash of that Mac's secret.

## Deploy

```bash
npm install
npx wrangler login
npx wrangler deploy
curl https://relay.sessionwatch.lajward.co/health
```

The custom domain needs the `lajward.co` zone in the same Cloudflare account. Wrangler creates the DNS record and certificate.

## Develop

```bash
npx wrangler dev --port 8787 --ip 127.0.0.1
```

Then run the end-to-end tests from the repo root:

```bash
RELAY_URL=ws://127.0.0.1:8787 swift test --filter RelayLiveTests
```

## Metrics

The relay counts what it does, never what it carries: no payloads, room ids, secrets, stream ids or IPs.

- Counted: Mac connects and replacements, auth failures, streams opened / answered / closed, frames and ciphertext bytes each way, and errors by kind (`err_mac_offline`, `err_rate_limited`, `err_too_many_streams`, `err_no_such_stream`, `err_stream_taken`, `err_attach_timeout`, `err_frame_too_large`, `err_mac_not_ready`, `err_socket_error`). Gauges: active Mac rooms and open streams.
- Each `MacRoom` adds to in-memory counters and sends them in one batch 5 s later (its alarm) to a single `RelayMetrics` Durable Object, so relaying a frame costs two additions. Counters are kept in total and per deployment (Worker version id, last 10). Best effort: a batch can be lost if a room is evicted before it flushes.
- Workers Analytics Engine wasn't used: reading it needs a Cloudflare API token and the SQL API, and it can't hold a gauge like active rooms.

Turn it on once with a secret (until then `/v1/metrics` answers 404):

```bash
npx wrangler secret put METRICS_TOKEN      # paste a long random value, e.g. from: openssl rand -hex 24
curl -H "Authorization: Bearer <token>" https://relay.sessionwatch.lajward.co/v1/metrics
```

Locally, put `METRICS_TOKEN=…` in `relay/.dev.vars` (gitignored), run `wrangler dev` on port 8788 and `npm run smoke:metrics`.

## Limits

- 32 streams per Mac.
- 60 phone connects a minute.
- 1 MiB frames.
- The Mac must answer a stream within 15 s.
- A second Mac connecting with the same room id and secret replaces the first (close code 4409). A Mac with a different secret is refused (4401).
