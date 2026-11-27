import { afterEach, describe, expect, it, vi } from "vitest";
import { FakeEventSource } from "../test/fakeEventSource";
import {
  getConnection,
  openEventStream,
  subscribe,
  type Connection,
  type ProbeResult,
  type ServerEvent,
} from "./events";

function stream(probe: () => Promise<ProbeResult> = () => Promise.resolve("ok")) {
  const events: ServerEvent[] = [];
  const states: Connection[] = [];
  const handle = openEventStream({
    onEvent: (event) => events.push(event),
    onConnection: (state) => states.push(state),
    probe,
  });
  return { events, states, handle };
}

describe("events", () => {
  afterEach(() => vi.useRealTimers());

  it("switches to reconnecting on error and back to live on open", async () => {
    vi.useFakeTimers();
    const { states, handle } = stream();
    expect(FakeEventSource.latest().url).toBe("/api/events");
    FakeEventSource.latest().open();
    expect(states.at(-1)).toBe("live");

    FakeEventSource.latest().fail();
    expect(states.at(-1)).toBe("reconnecting");
    expect(FakeEventSource.open()).toHaveLength(0);

    await vi.advanceTimersByTimeAsync(1_000);
    expect(FakeEventSource.instances).toHaveLength(2);
    FakeEventSource.latest().open();
    expect(states.at(-1)).toBe("live");
    handle.close();
  });

  it("backs off from 1 s to a 30 s cap and starts over after a good connection", async () => {
    vi.useFakeTimers();
    const { handle } = stream();
    const waits: number[] = [];
    for (let attempt = 0; attempt < 7; attempt++) {
      const before = FakeEventSource.instances.length;
      FakeEventSource.latest().fail();
      let waited = 0;
      while (FakeEventSource.instances.length === before) {
        await vi.advanceTimersByTimeAsync(500);
        waited += 500;
      }
      waits.push(waited);
    }
    expect(waits).toEqual([1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]);

    FakeEventSource.latest().open();
    const before = FakeEventSource.instances.length;
    FakeEventSource.latest().fail();
    await vi.advanceTimersByTimeAsync(1_000);
    expect(FakeEventSource.instances.length).toBe(before + 1);
    handle.close();
  });

  it("stops reconnecting when the app asks to sign in again", async () => {
    vi.useFakeTimers();
    const { states } = stream(() => Promise.resolve("signedOut"));
    FakeEventSource.latest().fail();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(states.at(-1)).toBe("signedOut");
    expect(FakeEventSource.instances).toHaveLength(1);
  });

  it("keeps trying when the app doesn't answer the check", async () => {
    vi.useFakeTimers();
    const { states, handle } = stream(() => Promise.reject(new Error("offline")));
    FakeEventSource.latest().fail();
    await vi.advanceTimersByTimeAsync(1_000);
    expect(FakeEventSource.instances).toHaveLength(2);
    expect(states.at(-1)).toBe("reconnecting");
    handle.close();
  });

  it("says the app isn't answering after three checks get no answer, and keeps trying", async () => {
    vi.useFakeTimers();
    const { states, handle } = stream(() => Promise.resolve("unreachable"));
    for (const wait of [1_000, 2_000]) {
      FakeEventSource.latest().fail();
      await vi.advanceTimersByTimeAsync(wait);
      expect(states.at(-1)).toBe("reconnecting");
    }
    FakeEventSource.latest().fail();
    await vi.advanceTimersByTimeAsync(0);
    expect(states.at(-1)).toBe("unreachable");
    // Still retrying: the app may come back (then a 401 asks to sign in again).
    await vi.advanceTimersByTimeAsync(4_000);
    expect(FakeEventSource.instances).toHaveLength(4);
    FakeEventSource.latest().fail();
    await vi.advanceTimersByTimeAsync(0);
    expect(states.at(-1)).toBe("unreachable");
    await vi.advanceTimersByTimeAsync(8_000);
    expect(FakeEventSource.instances).toHaveLength(5);
    FakeEventSource.latest().open();
    expect(states.at(-1)).toBe("live");
    handle.close();
  });

  it("starts the count over once a check gets an answer", async () => {
    vi.useFakeTimers();
    const answers: ProbeResult[] = ["unreachable", "unreachable", "ok", "unreachable", "unreachable"];
    const { states, handle } = stream(() => Promise.resolve(answers.shift() ?? "ok"));
    for (const wait of [1_000, 2_000, 4_000, 8_000, 16_000]) {
      FakeEventSource.latest().fail();
      await vi.advanceTimersByTimeAsync(wait);
    }
    expect(states).not.toContain("unreachable");
    handle.close();
  });

  it("delivers events by name and skips malformed data", () => {
    const { events, handle } = stream();
    const source = FakeEventSource.latest();
    source.emit("hello", { online: true, recording: "idle" });
    source.emitRaw("sessionChanged", "{not json");
    source.emit("sessionChanged", { id: "S1" });
    source.emit("liveTurn", { id: "t1", source: "mic", start: 1, end: 2, text: "Hi", language: "en" });
    source.emit("spend", { requests: 2, promptTokens: 0, completionTokens: 0, reportedCostUSD: 0.01, unpricedRequests: 0 });
    source.emit("catalog", {});
    expect(events).toEqual([
      { type: "hello", online: true, recording: "idle" },
      { type: "sessionChanged", id: "S1" },
      { type: "liveTurn", turn: { id: "t1", source: "mic", start: 1, end: 2, text: "Hi", language: "en" } },
      {
        type: "spend",
        usage: { requests: 2, promptTokens: 0, completionTokens: 0, reportedCostUSD: 0.01, unpricedRequests: 0 },
      },
      { type: "catalog" },
    ]);
    handle.close();
  });

  it("shares one connection and closes it with the last subscriber", () => {
    const first = vi.fn();
    const second = vi.fn();
    const stopFirst = subscribe(first);
    const stopSecond = subscribe(second);
    expect(FakeEventSource.open()).toHaveLength(1);
    FakeEventSource.latest().open();
    expect(getConnection()).toBe("live");
    FakeEventSource.latest().emit("connectivity", { online: false });
    expect(first).toHaveBeenCalledWith({ type: "connectivity", online: false });
    expect(second).toHaveBeenCalledWith({ type: "connectivity", online: false });
    stopFirst();
    expect(FakeEventSource.open()).toHaveLength(1);
    stopSecond();
    expect(FakeEventSource.open()).toHaveLength(0);
  });
});
