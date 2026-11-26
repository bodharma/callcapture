import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { App } from "./App";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it("shows the sign-in-again screen when the probe is unauthorized", async () => {
  vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 401 })));
  render(<App />);
  expect(
    await screen.findByText("Open CallCapture from the menu bar to sign in again."),
  ).toBeTruthy();
});

it("renders the shell when signed in", async () => {
  vi.stubGlobal("fetch", vi.fn(async () => new Response('{"ok":true}', { status: 200 })));
  render(<App />);
  expect(await screen.findByText("CallCapture")).toBeTruthy();
});
