import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError, SignInRequired, apiGet, apiSend, errorText } from "./client";

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

  it("resolves a 204 with no body to undefined", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 204 })));
    await expect(apiSend("DELETE", "/api/sessions/S1")).resolves.toBeUndefined();
  });

  it("resolves any other 2xx with an empty body to undefined", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("", { status: 200 })));
    await expect(apiSend("POST", "/api/sessions/S1/reveal")).resolves.toBeUndefined();
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 202 })));
    await expect(apiSend("POST", "/api/x")).resolves.toBeUndefined();
  });

  it("exposes the error code and the server's message separately", async () => {
    stubFetch(409, { error: "nothing_to_save", message: "There is no note to save yet." });
    const err = (await apiSend("POST", "/api/sessions/S1/vault").catch((e: unknown) => e)) as ApiError;
    expect(err).toBeInstanceOf(ApiError);
    expect(err.status).toBe(409);
    expect(err.code).toBe("nothing_to_save");
    expect(err.message).toBe("There is no note to save yet.");
  });

  it("uses the error text as the message when there is no message (reprocess 409)", async () => {
    stubFetch(409, { error: "Stop the recording before processing a session." });
    const err = (await apiSend("POST", "/api/sessions/S1/reprocess").catch((e: unknown) => e)) as ApiError;
    expect(err.message).toBe("Stop the recording before processing a session.");
  });

  it("falls back to the status text for a non-JSON error body", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("oops", { status: 500, statusText: "Internal Server Error" })),
    );
    const err = (await apiGet("/api/x").catch((e: unknown) => e)) as ApiError;
    expect(err.status).toBe(500);
    expect(err.code).toBeUndefined();
    expect(err.message).toBe("Internal Server Error");
  });

  it("says the app isn't answering when the request got no answer at all", () => {
    expect(errorText(new TypeError("Failed to fetch"))).toBe(
      "CallCapture isn't answering. If it restarted, open it again from the menu bar.",
    );
    expect(errorText(new ApiError(409, "Busy now"))).toBe("Busy now.");
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
