/**
 * Relay metrics: plain counters, never content. No payloads, room ids, secrets, stream ids or IPs are
 * recorded — only how many of each thing happened, per deployment (Worker version) and in total.
 *
 * Each MacRoom adds to its own in-memory counters and sends them here in one batch a few seconds
 * later (see MacRoom.flushMetrics), so relaying a frame costs a couple of additions, not a write.
 * Read them with GET /v1/metrics (Authorization: Bearer <METRICS_TOKEN>).
 */

import { DurableObject } from "cloudflare:workers";

/** Everything that is counted. Errors are the reasons a socket was refused or closed early. */
export const COUNTERS = [
  "mac_connects",          // Mac control sockets accepted
  "mac_replaced",          // a control socket replaced by a newer one for the same Mac
  "auth_failures",         // Mac sockets refused for a bad or missing secret
  "streams_opened",        // phone streams accepted
  "streams_closed",        // phone streams ended, for any reason
  "streams_attached",      // phone streams the Mac answered
  "frames_relayed",        // frames passed between a phone and its Mac
  "bytes_phone_to_mac",    // ciphertext bytes relayed phone → Mac
  "bytes_mac_to_phone",    // ciphertext bytes relayed Mac → phone
  "err_mac_offline",       // phone connected while its Mac had no control socket
  "err_rate_limited",      // over the phone connects-per-minute limit
  "err_too_many_streams",  // over the streams-per-Mac limit
  "err_no_such_stream",    // Mac data socket for a stream that is gone
  "err_stream_taken",      // second Mac data socket for one stream
  "err_attach_timeout",    // the Mac did not answer a stream in time
  "err_frame_too_large",   // frame over the size limit
  "err_mac_not_ready",     // phone sent too much before the Mac joined
  "err_socket_error",      // the runtime reported a socket error
] as const;

export type Counter = (typeof COUNTERS)[number];
export type Counts = Partial<Record<Counter, number>>;

/**
 * One batch from a room. `macRooms` holds +1 for the version a room's Mac came online under and -1 for
 * the one it left. A deploy disconnects every socket, so each version keeps its own gauge and the
 * current version's is exact even when an old room never got to report its Mac leaving.
 */
export interface MetricsBatch {
  version: string;
  counts: Counts;
  macRooms: Record<string, number>;
}

interface Bucket {
  first: number; // ms since epoch of the first batch
  last: number;
  counts: Counts;
  macRooms?: number;
}

interface Stored {
  since: number;
  total: Bucket;
  versions: Record<string, Bucket>; // Worker version id → its counters
}

const KEEP_VERSIONS = 10;

/** A single instance (idFromName("metrics")) that holds the totals. */
export class RelayMetrics extends DurableObject<object> {
  private state!: Stored;

  constructor(ctx: DurableObjectState, env: object) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const now = Date.now();
      this.state = (await ctx.storage.get<Stored>("metrics")) ?? {
        since: now, total: { first: now, last: now, counts: {} }, versions: {},
      };
    });
  }

  async add(batch: MetricsBatch): Promise<void> {
    const now = Date.now();
    const s = this.state;
    merge(s.total, batch.counts, now);
    merge((s.versions[batch.version] ??= { first: now, last: now, counts: {} }), batch.counts, now);
    for (const [version, delta] of Object.entries(batch.macRooms)) {
      const b = s.versions[version];
      if (b) b.macRooms = Math.max(0, (b.macRooms ?? 0) + delta);
      else if (delta > 0) s.versions[version] = { first: now, last: now, counts: {}, macRooms: delta };
    }
    const ids = Object.keys(s.versions);
    if (ids.length > KEEP_VERSIONS) {
      ids.sort((a, b) => s.versions[a].last - s.versions[b].last);
      for (const id of ids.slice(0, ids.length - KEEP_VERSIONS)) delete s.versions[id];
    }
    await this.ctx.storage.put("metrics", s);
  }

  async read(version: string): Promise<object> {
    const s = this.state;
    const full = (b: Bucket) => ({
      first: new Date(b.first).toISOString(),
      last: new Date(b.last).toISOString(),
      counts: Object.fromEntries(COUNTERS.map((c) => [c, b.counts[c] ?? 0])),
    });
    const cur = s.versions[version] ?? { first: Date.now(), last: Date.now(), counts: {} };
    return {
      since: new Date(s.since).toISOString(),
      version,
      // Gauges for the running deployment (a deploy disconnects every socket).
      active_mac_rooms: cur.macRooms ?? 0,
      open_streams: Math.max(0, (cur.counts.streams_opened ?? 0) - (cur.counts.streams_closed ?? 0)),
      deployment: full(cur),
      total: full(s.total),
      versions: Object.fromEntries(Object.entries(s.versions).map(([id, b]) => [id, { ...full(b), mac_rooms: b.macRooms ?? 0 }])),
    };
  }
}

function merge(b: Bucket, counts: Counts, now: number) {
  for (const [k, n] of Object.entries(counts) as [Counter, number][]) b.counts[k] = (b.counts[k] ?? 0) + n;
  b.last = now;
}
