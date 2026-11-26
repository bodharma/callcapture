import { act, fireEvent, screen, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { calls, mockApi } from "../test/api";
import { FakeEventSource } from "../test/fakeEventSource";
import { systemIdle, systemRecording } from "../test/liveFixtures";
import { renderAt } from "../test/render";

describe("TopBar recording control", () => {
  it("starts a recording from the web", async () => {
    const fetchFn = mockApi({
      "/api/system": systemIdle,
      "/api/sessions": [],
      "POST /api/recording/start": { status: 202, body: { started: true } },
    });
    renderAt("/sessions");
    fireEvent.click(await screen.findByRole("button", { name: "Record" }));
    await waitFor(() => expect(calls(fetchFn)).toContain("POST /api/recording/start"));
  });

  it("explains a refused start in a sentence", async () => {
    mockApi({
      "/api/system": systemIdle,
      "/api/sessions": [],
      "POST /api/recording/start": {
        status: 409,
        body: { error: "already_recording", message: "A recording is already running." },
      },
    });
    renderAt("/sessions");
    fireEvent.click(await screen.findByRole("button", { name: "Record" }));
    expect(await screen.findByText("A recording is already running.")).toBeTruthy();
  });

  it("shows REC and stops while recording", async () => {
    const fetchFn = mockApi({
      "/api/system": systemRecording,
      "/api/settings": { status: 500, body: { error: "failed" } },
      "POST /api/recording/stop": { status: 202, body: { started: true } },
    });
    renderAt("/settings/general");
    expect(await screen.findByText("REC")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Stop" }));
    await waitFor(() => expect(calls(fetchFn)).toContain("POST /api/recording/stop"));
  });

  it("follows recording events without polling", async () => {
    const fetchFn = mockApi({ "/api/system": systemIdle, "/api/sessions": [] });
    renderAt("/sessions");
    expect(await screen.findByRole("button", { name: "Record" })).toBeTruthy();
    act(() => FakeEventSource.latest().emit("recording", { state: "starting" }));
    expect(await screen.findByRole("button", { name: "Starting…" })).toBeTruthy();
    act(() => FakeEventSource.latest().emit("recording", { state: "recording" }));
    expect(await screen.findByRole("button", { name: "Stop" })).toBeTruthy();
    expect(calls(fetchFn).filter((call) => call === "GET /api/system")).toHaveLength(1);
  });

  it("disables Record with the reason while a session is processed", async () => {
    mockApi({ "/api/system": { ...systemIdle, recordingState: "processing" }, "/api/sessions": [] });
    renderAt("/sessions");
    const record = await screen.findByRole("button", { name: "Record" });
    expect((record as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText("Processing a session.")).toBeTruthy();
  });

  it("shows why the last start failed", async () => {
    mockApi({
      "/api/system": { ...systemIdle, problem: "Microphone access was denied." },
      "/api/sessions": [],
    });
    renderAt("/sessions");
    expect(await screen.findByText("Microphone access was denied.")).toBeTruthy();
  });

  it("shows the events connection state", async () => {
    mockApi({ "/api/system": systemIdle, "/api/sessions": [] });
    renderAt("/sessions");
    await screen.findByRole("button", { name: "Record" });
    act(() => FakeEventSource.latest().open());
    expect(await screen.findByText("Live")).toBeTruthy();
    act(() => FakeEventSource.latest().fail());
    expect(await screen.findByText("Reconnecting…")).toBeTruthy();
  });
});
