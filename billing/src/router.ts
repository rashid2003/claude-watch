import type { Env } from "./types";

export interface RouteContext {
  request: Request;
  env: Env;
  params: Record<string, string>;
  url: URL;
}

export type Handler = (ctx: RouteContext) => Promise<Response> | Response;

interface Route {
  method: string;
  segments: string[];
  handler: Handler;
}

/** Minimal path-segment router with `:param` support. */
export class Router {
  private routes: Route[] = [];

  on(method: string, path: string, handler: Handler): this {
    this.routes.push({ method, segments: splitPath(path), handler });
    return this;
  }

  get(path: string, handler: Handler): this {
    return this.on("GET", path, handler);
  }

  post(path: string, handler: Handler): this {
    return this.on("POST", path, handler);
  }

  delete(path: string, handler: Handler): this {
    return this.on("DELETE", path, handler);
  }

  /** Returns the matched handler's response, or null when nothing matches. */
  async handle(request: Request, env: Env): Promise<Response | null> {
    const url = new URL(request.url);
    const segments = splitPath(url.pathname);
    for (const route of this.routes) {
      if (route.method !== request.method) continue;
      const params = match(route.segments, segments);
      if (!params) continue;
      return route.handler({ request, env, params, url });
    }
    return null;
  }
}

function splitPath(path: string): string[] {
  return path.split("/").filter((s) => s.length > 0);
}

function match(pattern: string[], actual: string[]): Record<string, string> | null {
  if (pattern.length !== actual.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < pattern.length; i++) {
    const p = pattern[i];
    if (p.startsWith(":")) params[p.slice(1)] = decodeURIComponent(actual[i]);
    else if (p !== actual[i]) return null;
  }
  return params;
}
