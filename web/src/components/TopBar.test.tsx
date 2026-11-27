import { act, fireEvent, screen, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { calls, mockApi } from "../test/api";
import { FakeEventSource } from "../test/fakeEventSource";
import { recordButton, recordingEvent, stopButton, systemIdle, systemRecording } from "../test/liveFixtures";
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
    act(() =>
      FakeEventSource.latest().emit("recording", recordingEvent("starting", true, { action: "start", enabled: false })),
    );
    expect(await screen.findByRole("button", { name: "Starting…" })).toBeTruthy();
    act(() => FakeEventSource.latest().emit("recording", recordingEvent("recording", true, stopButton)));
    expect(await screen.findByRole("button", { name: "Stop" })).toBeTruthy();
    expect(calls(fetchFn).filter((call) => call === "GET /api/system")).toHaveLength(1);
  });

  it("disables Record with the app's reason while a session is processed", async () => {
    const reason = "A session is being processed. Record again when it finishes, or cancel it from the menu.";
    mockApi({
      "/api/system": { ...systemIdle, recordingState: "processing", button: { action: "start", enabled: false, reason } },
      "/api/sessions": [],
    });
    renderAt("/sessions");
    const record = await screen.findByRole("button", { name: "Record" });
    expect((record as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText(reason)).toBeTruthy();
  });

  it("disables Record while the live speech model downloads, as the menu does", async () => {
    const reason = "The live speech model is downloading. Wait for it or cancel it from the menu.";
    mockApi({
      "/api/system": { ...systemIdle, button: { action: "start", enabled: false, reason } },
      "/api/sessions": [],
    });
    renderAt("/sessions");
    const record = await screen.findByRole("button", { name: "Record" });
    expect((record as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText(reason)).toBeTruthy();
  });

  it("after a failed stop offers Record like the menu, with the failure", async () => {
    mockApi({
      "/api/system": { ...systemIdle, recording: true, button: recordButton, problem: "The capture didn't stop." },
      "/api/sessions": [],
    });
    renderAt("/sessions");
    const record = await screen.findByRole("button", { name: "Record" });
    expect((record as HTMLButtonElement).disabled).toBe(false);
    expect(screen.queryByText("REC")).toBeNull();
    expect(screen.queryByRole("button", { name: "Stop" })).toBeNull();
    expect(screen.getByText("The capture didn't stop.")).toBeTruthy();
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
