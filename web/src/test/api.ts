import { vi } from "vitest";

/** A canned answer: a status plus an optional JSON body (no body for 204). */
export interface Reply {
  status?: number;
  body?: unknown;
}

export type Handler = (init: RequestInit | undefined, url: URL) => unknown;

/** A handler, a canned `Reply`, or a plain JSON value answered with 200. */
export type RouteValue = Handler | Reply | object | string | number | boolean | null;

/**
 * Stubs `fetch` with a route table keyed by "METHOD /path" (query ignored) or
 * "/path" for GET. A handler returns a `Reply` or a plain JSON value (200).
 * Unknown routes answer 404 `{"error":"not_found"}`.
 */
export function mockApi(routes: Record<string, RouteValue>) {
  const fetchFn = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input), "http://127.0.0.1");
    const method = (init?.method ?? "GET").toUpperCase();
    const route =
      routes[`${method} ${url.pathname}`] ?? (method === "GET" ? routes[url.pathname] : undefined);
    if (route === undefined) {
      return new Response(JSON.stringify({ error: "not_found" }), { status: 404 });
    }
    const value = typeof route === "function" ? (route as Handler)(init, url) : route;
    const reply = isReply(value) ? value : { status: 200, body: value };
    const status = reply.status ?? 200;
    const body = reply.body === undefined ? null : JSON.stringify(reply.body);
    return new Response(status === 204 ? null : body, { status });
  });
  vi.stubGlobal("fetch", fetchFn);
  return fetchFn;
}

function isReply(value: unknown): value is Reply {
  return (
    typeof value === "object" &&
    value !== null &&
    "status" in value &&
    typeof (value as Reply).status === "number"
  );
}

/** The calls made to `fetchFn` as "METHOD /path?query" strings. */
export function calls(fetchFn: ReturnType<typeof mockApi>): string[] {
  return fetchFn.mock.calls.map(([input, init]) => {
    const url = new URL(String(input), "http://127.0.0.1");
    return `${(init?.method ?? "GET").toUpperCase()} ${url.pathname}${url.search}`;
  });
}
