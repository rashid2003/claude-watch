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

## Limits

- 32 streams per Mac.
- 60 phone connects a minute.
- 1 MiB frames.
- The Mac must answer a stream within 15 s.
- A second Mac connecting with the same room id and secret replaces the first (close code 4409). A Mac with a different secret is refused (4401).
