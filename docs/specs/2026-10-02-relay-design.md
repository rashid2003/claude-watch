# Session Watch relay — design

**Date:** 2026-10-02 · **Status:** agreed

## Goal

Two ways for the iPhone to reach the Mac:

1. **Direct** — today's path (Tailscale / LAN to port 7433).
2. **Relay** — through our Cloudflare Worker at `wss://relay.sessionwatch.lajward.dev`. Needs no Tailscale, port forwarding or VPN. Both ends dial *out*.

The relay is a dumb, untrusted byte pipe. It never sees plaintext, tokens or chat content.

## Shape

```
iPhone app ──URLSession──▶ 127.0.0.1:<random> (RelayProxy, in-app)
                              │ encrypted frames
                              ▼
               wss://relay…/v1/phone/<macId>        Cloudflare Worker + Durable Object (one per macId)
                              ▲
                              │ encrypted frames
Mac  RelayConnector ──▶ wss://relay…/v1/mac/<macId>  (control)  +  /v1/mac/<macId>/<streamId> (one per phone stream)
                              │ plaintext bytes
                              ▼
                      127.0.0.1:7433  (existing BridgeServer, unchanged)
```

- Each phone TCP connection to the in-app proxy becomes one **stream**: a phone WebSocket to the relay.
- The DO tells the Mac's control socket `{"t":"open","sid":…}`. The Mac then dials a data WebSocket for that `sid` and pipes it to a fresh local TCP connection to `127.0.0.1:7433`.
- The DO forwards binary frames between the two sockets of a stream and closes both when one closes.
- So every existing route (REST, `/v1/stream` WebSocket, `/pair`) works through the relay with zero server changes. Loopback peers skip the tailnet-owner check, but the bearer token is still required.

## Identity and keys (Mac)

These are stored in `~/Library/Application Support/claude-watch/relay.json` (0600):

| Field | What it is |
|---|---|
| `macId` | 16 random bytes, base32 lowercase (26 chars) |
| `macSecret` | 32 random bytes, base64url. Authenticates the Mac to the relay. |
| `staticKey` | X25519 private key, raw base64 |

- **Relay registration:** the control socket sends header `Authorization: Bearer <macSecret>`.
- The DO stores `sha256(macSecret)` on first connect (trust on first use) and rejects a different secret afterwards (close 4401).
- The same secret is required on data sockets.

## Encryption (per stream, Noise-NK-like, CryptoKit)

1. **Phone → Mac, first frame (hello):**
   - `0x01 ‖ ephP.pub (32 bytes)`, where `ephP` is a fresh X25519 key for this stream.
2. **Mac → phone, first frame (reply):**
   - `0x02 ‖ ephM.pub (32 bytes)`, where `ephM` is a fresh X25519 key.
3. **Key derivation.** Both sides compute:
   - `ikm = DH(ephP, staticM) ‖ DH(ephP, ephM)`
   - `k = HKDF-SHA256(ikm, salt: "session-watch relay v1", info: ephP.pub ‖ ephM.pub ‖ staticM.pub, 64 bytes)`
   - The first 32 bytes are the phone→mac key; the last 32 are the mac→phone key.
4. **Data frames:** `ChaCha20-Poly1305(seal)`, with the nonce being a 96-bit little-endian counter per direction, starting at 0. The frame is `combined` minus the nonce (ciphertext ‖ tag). The receiver tracks its own counter; any failure closes the stream.

Properties:

- Only the holder of `staticM`, whose public key is pinned via the QR, can derive keys, so the phone authenticates the Mac.
- `ephM` stops replays.
- The phone authenticates to the Mac with the existing bearer token inside the tunnel.

## Pairing payload

`PairingPayload` v2 adds an optional `relay: RelayInfo { url, macId, macKey }`, where `macKey` is the X25519 public key as base64. v1 phones ignore it.

The phone stores it in `Credentials.relay` and pairs by:

- trying direct hosts first, then the relay;
- or only one of the two, depending on the phone's mode.

## Modes

- **Mac:**
  - Config `relayEnabled: Bool` (default true) and `relayURL` (default `wss://relay.sessionwatch.lajward.dev`).
  - Settings shows a toggle plus the relay status: connected / connecting / error.
  - The QR includes `relay` only when enabled.
- **Phone:**
  - Mac tab picker "connect via": **auto** (direct first, then relay), **direct**, or **relay**.
  - Stored per pairing.
  - The status line shows the path in use: `tailscale` / `relay`.

## Worker (`relay/`, TypeScript, wrangler)

- **Routes:** `GET /v1/mac/:macId` (control), `GET /v1/mac/:macId/:sid` (data), `GET /v1/phone/:macId` (stream), `GET /health`.
- **Durable Object** `MacRoom`, keyed by macId. It uses the WebSocket Hibernation API (`state.acceptWebSocket`, tags `ctrl` / `p:<sid>` / `m:<sid>`).
- **Opening a stream:**
  - A phone stream gets a random `sid`, buffers up to 64 frames or 1 MB until the Mac's data socket attaches, and is dropped after 15 s.
  - If no control socket is present, the phone socket is closed with 4404 "mac offline".
- **Limits:**
  - 32 concurrent streams per mac;
  - frame size ≤ 1 MiB;
  - phone connects ≤ 60/min per macId;
  - macId must match `^[a-z2-7]{26}$`.
- Control socket keepalive: ping every 30 s, sent as a `{"t":"ping"}` text frame from the Mac.
- No storage beyond `secretHash`. No logging of payloads.

## Out of scope (later)

- Push through the relay (APNs already goes direct from the Mac).
- Multi-Mac accounts.
- A web dashboard.
