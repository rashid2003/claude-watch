/**
 * Session Watch relay: a dumb pipe between an iPhone and its Mac when neither can reach the other
 * directly. Both ends dial out to here. Every byte that crosses is end-to-end encrypted by the apps
 * (see docs/specs/2026-10-02-relay-design.md); this Worker never sees keys, tokens or chat content.
 *
 *   GET /v1/mac/:macId          Mac control socket (one per Mac), Authorization: Bearer <macSecret>
 *   GET /v1/mac/:macId/:sid     Mac data socket for one phone stream, same secret
 *   GET /v1/phone/:macId        one phone stream
 *   GET /health
 */

import { DurableObject } from "cloudflare:workers";

export interface Env {
  ROOM: DurableObjectNamespace<MacRoom>;
}

const MAC_ID = /^[a-z2-7]{26}$/;
const SID = /^[0-9a-f]{16}$/;
const MAX_FRAME = 1 << 20;
const MAX_STREAMS = 32;
const PHONE_CONNECTS_PER_MIN = 60;
const ATTACH_TIMEOUT_MS = 15_000;
const MAX_PENDING_BYTES = 1500; // pending frames live in the socket attachment (2 KB cap)

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const p = url.pathname.split("/").filter(Boolean);
    if (p.length === 1 && p[0] === "health") return new Response("ok\n");
    if (p[0] !== "v1" || p.length < 3 || !MAC_ID.test(p[2])) return new Response("not found\n", { status: 404 });
    const valid =
      (p[1] === "mac" && (p.length === 3 || (p.length === 4 && SID.test(p[3])))) ||
      (p[1] === "phone" && p.length === 3);
    if (!valid) return new Response("not found\n", { status: 404 });
    if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket\n", { status: 426 });
    }
    return env.ROOM.get(env.ROOM.idFromName(p[2])).fetch(req);
  },
} satisfies ExportedHandler<Env>;

type Role = "ctrl" | "p" | "m";
interface Attachment {
  role: Role;
  sid?: string;
  opened?: number;   // phone: when the stream was opened
  attached?: boolean; // phone: the Mac's data socket has joined
  pending?: string[]; // phone: base64 frames sent before the Mac joined
}

/** One per Mac. Holds the Mac's control socket and pairs phone streams with Mac data sockets. */
export class MacRoom extends DurableObject<Env> {
  private connects: number[] = [];

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"t":"ping"}', '{"t":"pong"}'));
  }

  async fetch(req: Request): Promise<Response> {
    const p = new URL(req.url).pathname.split("/").filter(Boolean);
    if (p[1] === "phone") return this.phone();
    if (!(await this.authorized(req))) return closed(4401, "bad mac secret");
    return p.length === 3 ? this.control() : this.data(p[3]);
  }

  // MARK: Connections

  private control(): Response {
    for (const old of this.ctx.getWebSockets("ctrl")) safeClose(old, 4409, "replaced");
    const [client, server] = pair();
    this.ctx.acceptWebSocket(server, ["ctrl"]);
    server.serializeAttachment({ role: "ctrl" } satisfies Attachment);
    return upgrade(client);
  }

  private phone(): Response {
    const ctrl = this.ctx.getWebSockets("ctrl")[0];
    if (!ctrl) return closed(4404, "mac offline");
    const now = Date.now();
    this.connects = this.connects.filter((t) => now - t < 60_000);
    if (this.connects.length >= PHONE_CONNECTS_PER_MIN) return closed(4429, "too many connections");
    if (this.ctx.getWebSockets("p").length >= MAX_STREAMS) return closed(4429, "too many streams");
    this.connects.push(now);

    const sid = randomHex(8);
    const [client, server] = pair();
    this.ctx.acceptWebSocket(server, ["p", `p:${sid}`]);
    server.serializeAttachment({ role: "p", sid, opened: now, attached: false, pending: [] } satisfies Attachment);
    ctrl.send(JSON.stringify({ t: "open", sid }));
    this.ctx.storage.setAlarm(now + ATTACH_TIMEOUT_MS);
    return upgrade(client);
  }

  private data(sid: string): Response {
    const phone = this.ctx.getWebSockets(`p:${sid}`)[0];
    if (!phone) return closed(4404, "no such stream");
    const att = phone.deserializeAttachment() as Attachment;
    if (att.attached) return closed(4409, "stream taken");
    const [client, server] = pair();
    this.ctx.acceptWebSocket(server, ["m", `m:${sid}`]);
    server.serializeAttachment({ role: "m", sid } satisfies Attachment);
    for (const f of att.pending ?? []) server.send(fromB64(f));
    phone.serializeAttachment({ ...att, attached: true, pending: [] } satisfies Attachment);
    return upgrade(client);
  }

  // MARK: Hibernation handlers

  async webSocketMessage(ws: WebSocket, msg: string | ArrayBuffer): Promise<void> {
    const att = ws.deserializeAttachment() as Attachment;
    const size = typeof msg === "string" ? msg.length : msg.byteLength;
    if (size > MAX_FRAME) return this.drop(ws, att, 1009, "frame too large");
    if (att.role === "ctrl") return; // only pings, answered by the auto-response
    const peer = this.ctx.getWebSockets(`${att.role === "p" ? "m" : "p"}:${att.sid}`)[0];
    if (peer) return peer.send(msg);
    if (att.role === "m") return this.drop(ws, att, 1000, "phone gone");
    // Phone talking before the Mac joined: hold the frame (only the hello is expected here).
    const bytes = typeof msg === "string" ? new TextEncoder().encode(msg) : new Uint8Array(msg);
    const pending = [...(att.pending ?? []), toB64(bytes)];
    if (pending.join("").length > MAX_PENDING_BYTES) return this.drop(ws, att, 1009, "mac not ready");
    ws.serializeAttachment({ ...att, pending } satisfies Attachment);
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    const att = ws.deserializeAttachment() as Attachment;
    this.drop(ws, att, code === 1005 || code === 1006 ? 1000 : code, reason);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.drop(ws, ws.deserializeAttachment() as Attachment, 1011, "error");
  }

  /** Phone streams whose Mac never joined. */
  async alarm(): Promise<void> {
    const now = Date.now();
    let next = Infinity;
    for (const ws of this.ctx.getWebSockets("p")) {
      const att = ws.deserializeAttachment() as Attachment;
      if (att.attached) continue;
      const due = (att.opened ?? 0) + ATTACH_TIMEOUT_MS;
      if (due <= now) safeClose(ws, 4408, "mac did not answer");
      else next = Math.min(next, due);
    }
    if (next !== Infinity) await this.ctx.storage.setAlarm(next);
  }

  // MARK: Helpers

  /** Closes a socket and, for a stream, its other half. */
  private drop(ws: WebSocket, att: Attachment, code: number, reason: string) {
    safeClose(ws, code, reason);
    if (att.role === "ctrl") return;
    const peer = this.ctx.getWebSockets(`${att.role === "p" ? "m" : "p"}:${att.sid}`)[0];
    if (peer) safeClose(peer, code, reason);
  }

  /** Trust on first use: the first secret a Mac presents becomes its secret. */
  private async authorized(req: Request): Promise<boolean> {
    const m = /^Bearer (\S{32,})$/.exec(req.headers.get("Authorization") ?? "");
    if (!m) return false;
    const hash = await sha256(m[1]);
    const stored = await this.ctx.storage.get<string>("secretHash");
    if (!stored) {
      await this.ctx.storage.put("secretHash", hash);
      return true;
    }
    return timingSafeEqual(stored, hash);
  }
}

function pair(): [WebSocket, WebSocket] {
  const { 0: client, 1: server } = new WebSocketPair();
  return [client, server];
}

function upgrade(client: WebSocket): Response {
  return new Response(null, { status: 101, webSocket: client });
}

/** Accept then close at once, so the app sees a WebSocket close code rather than a bare HTTP error. */
function closed(code: number, reason: string): Response {
  const [client, server] = pair();
  server.accept();
  server.close(code, reason);
  return upgrade(client);
}

function safeClose(ws: WebSocket, code: number, reason: string) {
  try {
    ws.close(code, reason.slice(0, 120));
  } catch {
    // already closed
  }
}

function randomHex(bytes: number): string {
  return [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return toB64(new Uint8Array(d));
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function toB64(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s);
}

function fromB64(s: string): Uint8Array {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}
