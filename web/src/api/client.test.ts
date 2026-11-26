import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError, SignInRequired, apiGet, apiSend } from "./client";

function stubFetch(status: number, body: unknown) {
  const fn = vi.fn(async () => new Response(JSON.stringify(body), { status }));
  vi.stubGlobal("fetch", fn);
  return fn;
}

afterEach(() => vi.unstubAllGlobals());

describe("api client", () => {
  it("rejects a 401 with SignInRequired", async () => {
    stubFetch(401, { error: "signin_required" });
    await expect(apiGet("/api/health")).rejects.toBeInstanceOf(SignInRequired);
  });

  it("resolves the parsed body of a 200", async () => {
    const fetchFn = stubFetch(200, { ok: true });
    await expect(apiGet<{ ok: boolean }>("/api/health")).resolves.toEqual({ ok: true });
    expect(fetchFn).toHaveBeenCalledWith(
      "/api/health",
      expect.objectContaining({ credentials: "same-origin" }),
    );
  });

  it("rejects other failures with an ApiError carrying status and message", async () => {
    stubFetch(409, { error: "already recording" });
    const err = await apiGet("/api/x").catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect((err as ApiError).status).toBe(409);
    expect((err as ApiError).message).toBe("already recording");
  });

  it("sends JSON bodies with the given method", async () => {
    const fetchFn = stubFetch(200, { id: 1 });
    await expect(apiSend("POST", "/api/things", { a: 1 })).resolves.toEqual({ id: 1 });
    expect(fetchFn).toHaveBeenCalledWith(
      "/api/things",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ a: 1 }),
        credentials: "same-origin",
      }),
    );
  });
});
