import { act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { calls, mockApi, type RouteValue } from "../../test/api";
import { FakeEventSource } from "../../test/fakeEventSource";
import { sessionFixture } from "../../test/fixtures";
import { liveFixture, systemRecording } from "../../test/liveFixtures";
import { installMatchMedia } from "../../test/media";
import { renderAt } from "../../test/render";
import type { LiveSnapshot } from "../../api/liveTypes";

function liveApi(live: object = liveFixture(), extra: Record<string, RouteValue> = {}) {
  return mockApi({ "/api/system": systemRecording, "/api/live": live, ...extra });
}

function bodyOf(fetchFn: ReturnType<typeof mockApi>, route: string): unknown {
  const call = fetchFn.mock.calls.find(([input, init]) => `${init?.method ?? "GET"} ${String(input)}` === route);
  return call?.[1]?.body ? JSON.parse(String(call[1].body)) : undefined;
}

describe("LivePage", () => {
  it("compact layout under 480 px hides the transcript tab bar and keeps the note composer", async () => {
    installMatchMedia(420);
    liveApi();
    renderAt("/live");
    expect(await screen.findByText("Timing", { selector: ".compact-topic" })).toBeTruthy();
    expect(screen.queryByRole("tablist", { name: "Transcript" })).toBeNull();
    expect(screen.getByRole("textbox", { name: "Add a thought" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Add" })).toBeTruthy();
  });

  it("?compact=1 forces the compact layout in a wide window", async () => {
    liveApi();
    renderAt("/live?compact=1");
    expect(await screen.findByText("Who owns the rollback plan?")).toBeTruthy();
    expect(screen.queryByRole("tablist", { name: "Transcript" })).toBeNull();
    expect(screen.getByText("Remote · and then we ship")).toBeTruthy();
    expect(screen.getByText("ch.1 You · listening")).toBeTruthy();
    expect(screen.getByText("ch.2 Remote · listening")).toBeTruthy();
    expect(screen.getByText("Live notes so far: ≈ $0.012 · 3 requests")).toBeTruthy();
    expect(screen.getByText("REC")).toBeTruthy();
  });

  it("compact composer adds a note to the live map", async () => {
    const fetchFn = liveApi(liveFixture(), { "POST /api/live/note": { status: 204 } });
    renderAt("/live?compact=1");
    fireEvent.change(await screen.findByRole("textbox", { name: "Add a thought" }), {
      target: { value: "Ask about rollback" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Add" }));
    await waitFor(() => expect(calls(fetchFn)).toContain("POST /api/live/note"));
    expect(bodyOf(fetchFn, "POST /api/live/note")).toEqual({ text: "Ask about rollback", kind: "note" });
  });

  it("full layout offers every action of the live workspace", async () => {
    liveApi(liveFixture({ canChooseNotesLanguage: true, resolvedNotesLanguage: undefined, notesLanguage: "auto" }));
    renderAt("/live");
    expect(await screen.findByRole("heading", { level: 1, name: "Weekly sync" })).toBeTruthy();
    for (const name of ["What did I miss?", "Add thought", "Back to live", "Export…", "Add topic", "Unpin topic"]) {
      expect(screen.getByRole("button", { name }), name).toBeTruthy();
    }
    expect(screen.getByRole("tablist", { name: "Transcript" })).toBeTruthy();
    expect(screen.getByRole("combobox", { name: "Choose notes language" })).toBeTruthy();
    expect(screen.getByRole("combobox", { name: "Move Timing under" })).toBeTruthy();
    expect(screen.getByRole("combobox", { name: "Merge Timing into" })).toBeTruthy();
    expect(screen.getByRole("textbox", { name: "New title for Timing" })).toBeTruthy();
    expect(screen.getByRole("textbox", { name: "Your thought or question" })).toBeTruthy();
    expect(screen.getByText("Current mapped topic: Timing")).toBeTruthy();
    expect(screen.getByText("Live notes so far: ≈ $0.012 · 3 requests")).toBeTruthy();
    const outline = screen.getByRole("navigation", { name: "Topics" });
    expect(within(outline).getByRole("button", { name: /Release plan/ })).toBeTruthy();
    expect(within(outline).getByRole("button", { name: /Timing/ }).getAttribute("aria-current")).toBe("true");
    const memos = screen.getByRole("region", { name: "Notes on Timing" });
    expect(within(memos).getByText("Your note")).toBeTruthy();
    expect(within(memos).getAllByRole("button", { name: "Edit" })).toHaveLength(2);
  });

  it("topic actions post to the live map", async () => {
    const fetchFn = liveApi(liveFixture(), {
      "POST /api/live/topics/release/select": { status: 204 },
      "POST /api/live/topics/timing/rename": { status: 204 },
      "POST /api/live/topics/timing/pin": { status: 204 },
      "POST /api/live/topics/timing/merge": { status: 204 },
      "POST /api/live/memos/timing/m2/pin": { status: 204 },
      "POST /api/live/catch-up": { status: 204 },
    });
    renderAt("/live");
    const outline = await screen.findByRole("navigation", { name: "Topics" });
    fireEvent.click(within(outline).getByRole("button", { name: /Release plan/ }));
    await waitFor(() => expect(calls(fetchFn)).toContain("POST /api/live/topics/release/select"));

    fireEvent.change(screen.getByRole("textbox", { name: "New title for Timing" }), { target: { value: "Schedule" } });
    fireEvent.click(screen.getByRole("button", { name: "Rename" }));
    await waitFor(() => expect(bodyOf(fetchFn, "POST /api/live/topics/timing/rename")).toEqual({ title: "Schedule" }));

    fireEvent.click(screen.getByRole("button", { name: "Unpin topic" }));
    await waitFor(() => expect(bodyOf(fetchFn, "POST /api/live/topics/timing/pin")).toEqual({ pinned: false }));

    fireEvent.change(screen.getByRole("combobox", { name: "Merge Timing into" }), { target: { value: "release" } });
    fireEvent.click(screen.getByRole("button", { name: "Merge" }));
    await waitFor(() => expect(bodyOf(fetchFn, "POST /api/live/topics/timing/merge")).toEqual({ targetID: "release" }));

    fireEvent.click(screen.getAllByRole("button", { name: "Pin note" })[0]);
    await waitFor(() => expect(bodyOf(fetchFn, "POST /api/live/memos/timing/m2/pin")).toEqual({ pinned: true }));

    fireEvent.click(screen.getByRole("button", { name: "What did I miss?" }));
    await waitFor(() => expect(calls(fetchFn)).toContain("POST /api/live/catch-up"));
  });

  it("shows a refused action as a sentence next to the control", async () => {
    liveApi(liveFixture(), {
      "POST /api/live/topics/timing/move": {
        status: 409,
        body: { error: "refused", message: "A topic can't move under itself or one of its own subtopics." },
      },
    });
    renderAt("/live");
    fireEvent.change(await screen.findByRole("combobox", { name: "Move Timing under" }), { target: { value: "" } });
    fireEvent.click(screen.getByRole("button", { name: "Move" }));
    expect(await screen.findByText("A topic can't move under itself or one of its own subtopics.")).toBeTruthy();
  });

  it("offline, automatic notes show the app's offline message", async () => {
    mockApi({ "/api/system": { ...systemRecording, online: false }, "/api/live": liveFixture() });
    renderAt("/live");
    expect(
      await screen.findByText("Automatic notes paused: offline. Transcript and manual notes continue."),
    ).toBeTruthy();
    expect(screen.getByText(/Catch-up shows the original speech/)).toBeTruthy();
  });

  it("without a meeting, points at the last meeting's saved map", async () => {
    liveApi({ active: false, lastSessionID: "S9" });
    renderAt("/live");
    expect(await screen.findByText(/No live meeting is running/)).toBeTruthy();
    expect(screen.getByRole("link", { name: "Open the last meeting's map" }).getAttribute("href")).toBe(
      "/sessions/S9/live",
    );
  });

  it("follows live turns and partial speech from the events stream", async () => {
    liveApi();
    renderAt("/live");
    expect(await screen.findAllByText("If staging is green.")).not.toHaveLength(0);
    const source = FakeEventSource.latest();
    act(() => {
      source.emit("liveTurn", { id: "t3", source: "system", start: 5, end: 6, text: "Monday then.", language: "en" });
      source.emit("partial", { source: "mic", text: "agreed" });
    });
    expect(await screen.findByText("Monday then.")).toBeTruthy();
    expect(screen.getByText("You · partial: agreed")).toBeTruthy();
  });
});

describe("SavedLivePage", () => {
  const saved: LiveSnapshot = liveFixture({
    active: false,
    sessionID: "S2",
    title: "Past sync",
    status: "Saved live map",
    processingStatus: "Saved live map",
    selectedTopicID: undefined,
    partials: {},
    speechRunning: false,
  });

  function savedApi(extra: Record<string, RouteValue> = {}) {
    const session = sessionFixture({ id: "S2", title: "Past sync", hasLiveMap: true });
    return mockApi({
      "/api/system": { online: true, recording: false, version: "1.0", recordingState: "idle" },
      "/api/sessions": [session],
      "/api/sessions/S2/live": saved,
      ...extra,
    });
  }

  it("shows the saved map in the full layout without live-only controls", async () => {
    savedApi();
    renderAt("/sessions/S2/live");
    expect(await screen.findByRole("heading", { level: 1, name: "Past sync" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "What did I miss?" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Back to live" })).toBeNull();
    expect(screen.getByText("The meeting has ended, so there is nothing to catch up on.")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Export…" })).toBeTruthy();
    expect(screen.getByRole("link", { name: "Back to the session" }).getAttribute("href")).toBe("/sessions/S2");
  });

  it("keeps the selection in the page and edits the session's map", async () => {
    const fetchFn = savedApi({
      "POST /api/sessions/S2/live/note": { status: 204 },
      "POST /api/sessions/S2/live/topics/release/rename": { status: 204 },
    });
    renderAt("/sessions/S2/live");
    const outline = await screen.findByRole("navigation", { name: "Topics" });
    fireEvent.click(within(outline).getByRole("button", { name: /Release plan/ }));
    expect(calls(fetchFn).some((call) => call.includes("/select"))).toBe(false);

    fireEvent.change(screen.getByRole("textbox", { name: "New title for Release plan" }), {
      target: { value: "Release" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Rename" }));
    await waitFor(() => expect(calls(fetchFn)).toContain("POST /api/sessions/S2/live/topics/release/rename"));

    fireEvent.change(screen.getByRole("textbox", { name: "Your thought or question" }), {
      target: { value: "Follow up" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Add" }));
    await waitFor(() =>
      expect(bodyOf(fetchFn, "POST /api/sessions/S2/live/note")).toEqual({
        text: "Follow up",
        kind: "note",
        topicID: "release",
      }),
    );
  });
});
