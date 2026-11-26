import { render, screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { App } from "./App";
import { mockApi } from "./test/api";

it("shows the sign-in-again screen when the server answers 401", async () => {
  vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 401 })));
  render(<App />);
  expect(
    await screen.findByText("Open CallCapture from the menu bar to sign in again."),
  ).toBeTruthy();
});

it("opens the sessions archive when signed in", async () => {
  mockApi({ "/api/system": { online: true, recording: false, version: "1.0" }, "/api/sessions": [] });
  render(<App />);
  expect(await screen.findByText("CallCapture")).toBeTruthy();
  expect(await screen.findByText("Nothing recorded yet. Record a call from the menu bar.")).toBeTruthy();
  expect(window.location.pathname).toBe("/sessions");
});
