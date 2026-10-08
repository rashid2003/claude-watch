// End-to-end check of the relay metrics against a running `wrangler dev` (needs Node 22+):
//
//   echo "METRICS_TOKEN=$(openssl rand -hex 24)" > .dev.vars     # once; .dev.vars is gitignored
//   npx wrangler dev --port 8788 --ip 127.0.0.1
//   RELAY_URL=http://127.0.0.1:8788 npm run smoke:metrics
//
// It connects a fake Mac and phone, relays a few frames, and checks that the counters move, that the
// active-room gauge follows the Mac, and that no room id or secret shows up in /v1/metrics.

import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const base = process.env.RELAY_URL ?? "http://127.0.0.1:8788";
const ws = base.replace(/^http/, "ws");
const token = process.env.METRICS_TOKEN
  ?? readFileSync(new URL("../.dev.vars", import.meta.url), "utf8").match(/^METRICS_TOKEN=(.+)$/m)?.[1];
assert.ok(token, "set METRICS_TOKEN or put it in relay/.dev.vars");

const FLUSH_WAIT = 6_500; // rooms flush every 5 s
const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
const macId = Array.from({ length: 26 }, () => alphabet[Math.floor(Math.random() * 32)]).join("");
const secret = crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", "");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const metrics = async (auth = `Bearer ${token}`) => {
  const r = await fetch(`${base}/v1/metrics`, { headers: auth ? { Authorization: auth } : {} });
  return { status: r.status, text: await r.text() };
};
const read = async () => JSON.parse((await metrics()).text);
const open = (url, headers) =>
  new Promise((resolve, reject) => {
    const s = new WebSocket(url, { headers });
    s.binaryType = "arraybuffer";
    s.onopen = () => resolve(s);
    s.onerror = (e) => reject(e);
  });
const closed = (s) => new Promise((r) => (s.readyState === WebSocket.CLOSED ? r() : s.addEventListener("close", r)));
const next = (s) => new Promise((r) => s.addEventListener("message", (e) => r(e.data), { once: true }));

assert.equal((await metrics(null)).status, 401);
assert.equal((await metrics("Bearer wrong")).status, 401);
const before = await read();
const c0 = before.deployment.counts;

// Phone with no Mac online.
await closed(await open(`${ws}/v1/phone/${macId}`));

// Mac online, one stream, a few frames each way.
const mac = await open(`${ws}/v1/mac/${macId}`, { Authorization: `Bearer ${secret}` });
const opening = next(mac);
const phone = await open(`${ws}/v1/phone/${macId}`);
const { sid } = JSON.parse(await opening);
phone.send(new Uint8Array(10)); // held until the Mac joins
const data = await open(`${ws}/v1/mac/${macId}/${sid}`, { Authorization: `Bearer ${secret}` });
await next(data);
const back = next(phone);
data.send(new Uint8Array(20));
await back;

// Wrong secret for the same room.
await closed(await open(`${ws}/v1/mac/${macId}`, { Authorization: `Bearer ${"x".repeat(40)}` }));

await sleep(FLUSH_WAIT);
let m = await read();
let d = (k) => m.deployment.counts[k] - c0[k];
assert.equal(m.active_mac_rooms, before.active_mac_rooms + 1, "gauge counts the online Mac");
assert.equal(d("err_mac_offline"), 1);
assert.equal(d("streams_opened"), 1);
assert.equal(d("streams_attached"), 1);
assert.equal(d("auth_failures"), 1);
assert.equal(d("bytes_phone_to_mac"), 10);
assert.equal(d("bytes_mac_to_phone"), 20);
assert.equal(d("frames_relayed"), 2);

phone.close();
await closed(data);
mac.close();
await sleep(FLUSH_WAIT);
m = await read();
d = (k) => m.deployment.counts[k] - c0[k];
assert.equal(d("streams_closed"), 1, "stream end counted once");
assert.equal(m.active_mac_rooms, before.active_mac_rooms, "gauge drops when the Mac leaves");

const raw = (await metrics()).text;
assert.ok(!raw.includes(macId) && !raw.includes(secret) && !raw.includes(sid), "no ids or secrets in metrics");
console.log("relay metrics ok:", JSON.stringify({ version: m.version, active_mac_rooms: m.active_mac_rooms }));
