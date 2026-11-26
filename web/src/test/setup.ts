import { cleanup } from "@testing-library/react";
import { afterEach, beforeEach, vi } from "vitest";
import { FakeEventSource } from "./fakeEventSource";
import { installMatchMedia } from "./media";

// jsdom has no media playback: stub the element methods so tests can observe
// calls without jsdom's "Not implemented" noise.
Object.defineProperty(HTMLMediaElement.prototype, "play", {
  configurable: true,
  value: vi.fn(function play(this: HTMLMediaElement) {
    Object.defineProperty(this, "paused", { configurable: true, value: false });
    this.dispatchEvent(new Event("play"));
    return Promise.resolve();
  }),
});
Object.defineProperty(HTMLMediaElement.prototype, "pause", {
  configurable: true,
  value: vi.fn(function pause(this: HTMLMediaElement) {
    Object.defineProperty(this, "paused", { configurable: true, value: true });
    this.dispatchEvent(new Event("pause"));
  }),
});
Object.defineProperty(HTMLMediaElement.prototype, "load", {
  configurable: true,
  value: vi.fn(),
});

// jsdom has neither EventSource nor matchMedia; every page opens the events stream.
// Installed per test because afterEach unstubs every global.
beforeEach(() => {
  FakeEventSource.instances = [];
  vi.stubGlobal("EventSource", FakeEventSource);
  installMatchMedia(1280);
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});
