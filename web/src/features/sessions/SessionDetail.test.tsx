import { act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { SessionDTO } from "../../api/types";
import { calls, mockApi, type RouteValue } from "../../test/api";
import { FakeEventSource } from "../../test/fakeEventSource";
import { recordingEvent } from "../../test/liveFixtures";
import { analysisFixture, sessionFixture, transcriptFixture } from "../../test/fixtures";
import { renderAt } from "../../test/render";

vi.mock("wavesurfer.js", () => ({
  default: { create: vi.fn(() => ({ destroy: vi.fn(), on: vi.fn(() => () => {}) })) },
}));

const note = [
  "---",
  "type: call",
  "---",
  "# Weekly sync",
  "",
  "See [the plan](https://example.com/plan).",
  "",
  "Also [proto](//evil.example/x), [slash](/\\evil.example) and ![pic](//evil.example/p.png).",
  "",
  '<img src="x" onerror="alert(1)">',
  "",
  "![chart](https://tracker.example/pixel.png)",
  "",
  "- [ ] Draft the release notes",
].join("\n");

const options = {
  recordingTypes: [
    { value: "call_meeting", label: "Call / Meeting" },
    { value: "lecture", label: "Lecture" },
  ],
  languages: [
    { value: "auto", label: "Auto-detect" },
    { value: "en", label: "English" },
    { value: "uk", label: "Ukrainian" },
  ],
};

function api(session: SessionDTO = sessionFixture(), extra: Record<string, RouteValue> = {}) {
  return mockApi({
    "/api/system": { online: true, recording: false, version: "1.0", recordingState: "idle", button: { action: "start", enabled: true } },
    "/api/sessions": [session],
    [`/api/sessions/${session.id}`]: session,
    [`/api/sessions/${session.id}/transcript`]: transcriptFixture,
    [`/api/sessions/${session.id}/note`]: { markdown: note },
    [`/api/sessions/${session.id}/analysis`]: analysisFixture,
    [`/api/sessions/${session.id}/speakers`]: [
      { label: "Speaker 1", name: "Olena", renamed: true },
      { label: "Speaker 2", name: "Speaker 2", renamed: false },
    ],
    [`/api/sessions/${session.id}/peaks`]: [0.1, 0.4, 0.2],
    [`/api/sessions/${session.id}/markers`]: [
      { id: "m1", time: 522, kind: "decision", text: "Ship Friday if staging is green." },
    ],
    "/api/sessions/options": options,
    ...extra,
  });
}

describe("SessionDetail", () => {
  it("shows the title, the field row and the summary", async () => {
    api(sessionFixture({ hasLiveMap: true }));
    renderAt("/sessions/S1");
    expect(await screen.findByRole("heading", { level: 1, name: "Weekly sync, release plan" })).toBeTruthy();
    expect(screen.getByText("46 min")).toBeTruthy();
    expect(screen.getByText("Ukrainian")).toBeTruthy();
    expect(screen.getByText("Transcription $0.1000 · Processing $0.0200 · Total $0.1200")).toBeTruthy();
    expect(
      await screen.findByText("The team agreed to ship on Friday if staging is green by Thursday."),
    ).toBeTruthy();
    const decided = await screen.findByRole("region", { name: "Decided" });
    expect(within(decided).getByRole("button", { name: /08:42/ })).toBeTruthy();
    expect(screen.getByText("Olena confirms the migration window.").closest("li")).toBeTruthy();
    expect(screen.queryByRole("checkbox")).toBeNull();
  });

  it("folds the full note by default, below the structured lists", async () => {
    api();
    renderAt("/sessions/S1");
    const toggle = await screen.findByRole("button", { name: "Full note" });
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
    expect(screen.queryByRole("link", { name: "the plan" })).toBeNull();
    const todo = screen.getByRole("region", { name: "To do" });
    expect(todo.compareDocumentPosition(toggle) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    fireEvent.click(toggle);
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    expect(await screen.findByRole("link", { name: "the plan" })).toBeTruthy();
    fireEvent.click(toggle);
    expect(screen.queryByRole("link", { name: "the plan" })).toBeNull();
  });

  it("renders the note as Markdown without raw HTML or remote images", async () => {
    api();
    const { container } = renderAt("/sessions/S1");
    fireEvent.click(await screen.findByRole("button", { name: "Full note" }));
    const link = await screen.findByRole("link", { name: "the plan" });
    expect(link.getAttribute("target")).toBe("_blank");
    expect(link.getAttribute("rel")).toBe("noopener noreferrer");
    expect(container.querySelector("img")).toBeNull();
    expect(screen.queryByText("type: call")).toBeNull();
    expect(screen.getByText("Draft the release notes")).toBeTruthy();
    expect(container.querySelector('input[type="checkbox"]')).toBeNull();
  });

  it("opens protocol-relative and backslash note links outside the app", async () => {
    api();
    const { container } = renderAt("/sessions/S1");
    fireEvent.click(await screen.findByRole("button", { name: "Full note" }));
    const proto = await screen.findByRole("link", { name: "proto" });
    expect(new URL(proto.getAttribute("href") ?? "", window.location.href).origin).toBe("http://evil.example");
    expect(proto.getAttribute("target")).toBe("_blank");
    expect(proto.getAttribute("rel")).toBe("noopener noreferrer");
    const image = screen.getByRole("link", { name: "pic" });
    expect(image.getAttribute("target")).toBe("_blank");
    // Every note link that resolves to another origin must open outside the app.
    for (const link of Array.from(container.querySelectorAll<HTMLAnchorElement>(".note a"))) {
      const origin = new URL(link.getAttribute("href") ?? "", window.location.href).origin;
      if (origin !== window.location.origin) {
        expect(link.getAttribute("target")).toBe("_blank");
        expect(link.getAttribute("rel")).toBe("noopener noreferrer");
      }
    }
    expect(container.querySelector("img")).toBeNull();
  });

  it("offers each export only when there is something to export", async () => {
    api(sessionFixture({ hasNote: false }));
    renderAt("/sessions/S1");
    fireEvent.click(await screen.findByRole("button", { name: "Export" }));
    const json = screen.getByRole("link", { name: "JSON" });
    expect(json.getAttribute("href")).toBe("/api/sessions/S1/export?format=json");
    expect(screen.queryByRole("link", { name: "Markdown" })).toBeNull();
    expect((screen.getByRole("button", { name: "Save to vault" }) as HTMLButtonElement).disabled).toBe(true);
  });

  it("shows the reason when re-processing is refused", async () => {
    api(sessionFixture(), {
      "POST /api/sessions/S1/reprocess": {
        status: 409,
        body: { error: "Stop the recording before processing a session." },
      },
    });
    renderAt("/sessions/S1");
    fireEvent.click(await screen.findByRole("button", { name: "Re-process" }));
    expect(await screen.findByText(/Stop the recording before processing a session\./)).toBeTruthy();
  });

  it("shows progress after re-processing starts", async () => {
    let status = "transcribed";
    api(sessionFixture(), {
      "/api/sessions/S1": () => sessionFixture({ status }),
      "POST /api/sessions/S1/reprocess": () => {
        status = "transcribing";
        return { status: 202, body: { started: true } };
      },
    });
    renderAt("/sessions/S1");
    fireEvent.click(await screen.findByRole("button", { name: "Re-process" }));
    expect(await screen.findByText(/Processing this session/)).toBeTruthy();
  });

  it("saves to the vault and shows where", async () => {
    api(sessionFixture(), {
      "POST /api/sessions/S1/vault": { path: "/Users/me/Vault/Calls/Weekly sync.md" },
    });
    renderAt("/sessions/S1");
    fireEvent.click(await screen.findByRole("button", { name: "Save to vault" }));
    expect(await screen.findByText("/Users/me/Vault/Calls/Weekly sync.md")).toBeTruthy();
  });

  it("deletes after an in-page confirmation and returns to the list", async () => {
    const confirmSpy = vi.fn(() => true);
    vi.stubGlobal("confirm", confirmSpy);
    const fetchFn = api(sessionFixture(), { "DELETE /api/sessions/S1": { status: 204 } });
    const { router } = renderAt("/sessions/S1");
    fireEvent.click(await screen.findByRole("button", { name: "Delete session" }));
    expect(screen.getByText(/permanently removes the audio, transcript, note and analysis/)).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Delete session and files" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/sessions"));
    expect(calls(fetchFn)).toContain("DELETE /api/sessions/S1");
    expect(confirmSpy).not.toHaveBeenCalled();
  });

  it("shows the full transcript and renames a speaker", async () => {
    const fetchFn = api(sessionFixture(), { "PUT /api/sessions/S1/speakers/Speaker%202": { status: 204 } });
    renderAt("/sessions/S1?tab=transcript");
    expect(await screen.findByText("Who owns the rollback plan?")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Rename Speaker 2" }));
    fireEvent.change(screen.getByRole("textbox", { name: "Name for Speaker 2" }), {
      target: { value: "Taras" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Save name" }));
    await waitFor(() => expect(calls(fetchFn)).toContain("PUT /api/sessions/S1/speakers/Speaker%202"));
    const put = fetchFn.mock.calls.find(([, init]) => init?.method === "PUT");
    expect(put?.[1]?.body).toBe(JSON.stringify({ name: "Taras" }));
  });

  it("lists speakers with their talk stats and renames one from the Speakers tab", async () => {
    const fetchFn = api(sessionFixture(), { "PUT /api/sessions/S1/speakers/Speaker%202": { status: 204 } });
    renderAt("/sessions/S1?tab=speakers");
    expect(await screen.findByText("60% of the talking, 2,000 words, 40 turns, 120 words a minute.")).toBeTruthy();
    expect(screen.getByText("Speaker 1")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Rename Speaker 2" }));
    fireEvent.change(screen.getByRole("textbox", { name: "Name for Speaker 2" }), { target: { value: "Taras" } });
    fireEvent.click(screen.getByRole("button", { name: "Save name" }));
    await waitFor(() => expect(calls(fetchFn)).toContain("PUT /api/sessions/S1/speakers/Speaker%202"));
    await waitFor(() => expect(screen.queryByRole("textbox", { name: "Name for Speaker 2" })).toBeNull());
  });

  it("refreshes the page when the app reports the session changed", async () => {
    let status = "recording";
    api(sessionFixture({ status }), { "/api/sessions/S1": () => sessionFixture({ status }) });
    renderAt("/sessions/S1");
    const waiting = "Still recording. The tape shows up here after you stop.";
    expect(await screen.findByText(waiting)).toBeTruthy();
    status = "completed";
    act(() => FakeEventSource.latest().emit("sessionChanged", { id: "S1" }));
    await waitFor(() => expect(screen.queryByText(waiting)).toBeNull());
    expect(await screen.findByRole("button", { name: "Transcribe" })).toBeTruthy();
  });

  it("pauses playback as soon as a recording starts", async () => {
    api();
    const { container } = renderAt("/sessions/S1");
    const play = await screen.findByRole("button", { name: "Play" });
    fireEvent.click(play);
    const audio = container.querySelector("audio") as HTMLAudioElement;
    expect(audio.play).toHaveBeenCalled();
    act(() =>
      FakeEventSource.latest().emit("recording", recordingEvent("starting", true, { action: "start", enabled: false })),
    );
    expect(await screen.findByText("Playback is off while recording")).toBeTruthy();
    expect(audio.pause).toHaveBeenCalled();
  });

  it("keeps playback off after a failed stop, while the app still reports the block", async () => {
    api();
    renderAt("/sessions/S1");
    await screen.findByRole("button", { name: "Play" });
    act(() =>
      FakeEventSource.latest().emit("recording", recordingEvent("starting", true, { action: "start", enabled: false })),
    );
    expect(await screen.findByText("Playback is off while recording")).toBeTruthy();
    // The stop failed: the phase is idle and the menu offers Record, but the tap may still run.
    act(() =>
      FakeEventSource.latest().emit("recording", {
        ...recordingEvent("idle", true, { action: "start", enabled: true }),
        problem: "The capture didn't stop.",
      }),
    );
    expect(await screen.findByRole("button", { name: "Record" })).toBeTruthy();
    expect(screen.getByText("Playback is off while recording")).toBeTruthy();
    expect((screen.getByRole("button", { name: "Play" }) as HTMLButtonElement).disabled).toBe(true);
  });

  it("doesn't poll the session or the recording state", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const fetchFn = api(sessionFixture({ status: "transcribing" }));
    renderAt("/sessions/S1");
    expect(await screen.findByRole("heading", { level: 1 })).toBeTruthy();
    await vi.advanceTimersByTimeAsync(10_000);
    expect(calls(fetchFn).filter((call) => call === "GET /api/sessions/S1")).toHaveLength(1);
    expect(calls(fetchFn).filter((call) => call === "GET /api/system")).toHaveLength(1);
  });

  it("links the topic map tab to the live map view", async () => {
    api(sessionFixture({ hasLiveMap: true }));
    renderAt("/sessions/S1?tab=topics");
    const link = await screen.findByRole("link", { name: "Open the topic map" });
    expect(link.getAttribute("href")).toBe("/sessions/S1/live");
  });

  it("shows warnings and the last processing error", async () => {
    api(sessionFixture({ warning: "Speaker separation was skipped.", error: "Worker crashed" }));
    renderAt("/sessions/S1");
    expect(await screen.findByText("Speaker separation was skipped.")).toBeTruthy();
    expect(screen.getByText(/Worker crashed/)).toBeTruthy();
  });
});

describe("SessionDetail: edit, open the note, progress", () => {
  it("shows the source app and the app's choices in labelled selects", async () => {
    api();
    renderAt("/sessions/S1");
    expect(await screen.findByText("Zoom")).toBeTruthy();
    const speech = (await screen.findByLabelText("Speech")) as HTMLSelectElement;
    expect(speech.tagName).toBe("SELECT");
    expect(speech.value).toBe("uk");
    expect(within(speech).getByRole("option", { name: "Auto-detect" })).toBeTruthy();
    expect((screen.getByLabelText("Type") as HTMLSelectElement).value).toBe("call_meeting");
    expect((screen.getByLabelText("Notes") as HTMLSelectElement).value).toBe("en");
  });

  it("saves a changed field at once and shows the server's value", async () => {
    let record = sessionFixture();
    const fetchFn = api(record, {
      "PATCH /api/sessions/S1": (init) => {
        record = { ...record, ...JSON.parse(String(init?.body)), notesLanguage: "uk" };
        return record;
      },
    });
    renderAt("/sessions/S1");
    const select = (await screen.findByLabelText("Type")) as HTMLSelectElement;
    fireEvent.change(select, { target: { value: "lecture" } });
    await waitFor(() => expect(calls(fetchFn)).toContain("PATCH /api/sessions/S1"));
    const patch = fetchFn.mock.calls.find(([, init]) => init?.method === "PATCH")?.[1];
    expect(JSON.parse(String(patch?.body))).toEqual({ recordingType: "lecture" });
    await waitFor(() => expect((screen.getByLabelText("Type") as HTMLSelectElement).value).toBe("lecture"));
    // The server's answer wins over what was picked.
    expect((screen.getByLabelText("Notes") as HTMLSelectElement).value).toBe("uk");
  });

  it("goes back to the saved value and says why when saving fails", async () => {
    api(sessionFixture(), {
      "PATCH /api/sessions/S1": { status: 400, body: { error: "invalid", message: "That isn't a value CallCapture knows for language." } },
    });
    renderAt("/sessions/S1");
    const select = (await screen.findByLabelText("Speech")) as HTMLSelectElement;
    fireEvent.change(select, { target: { value: "en" } });
    const alert = await screen.findByRole("alert");
    expect(alert.textContent).toContain("Couldn't change the speech language.");
    expect(alert.textContent).toContain("That isn't a value CallCapture knows for language.");
    expect((screen.getByLabelText("Speech") as HTMLSelectElement).value).toBe("uk");
  });

  it("offers Open note only when the session has a note file", async () => {
    const fetchFn = api(sessionFixture(), { "POST /api/sessions/S1/open-note": { status: 204 } });
    renderAt("/sessions/S1");
    fireEvent.click(await screen.findByRole("button", { name: "Open note" }));
    await waitFor(() => expect(calls(fetchFn)).toContain("POST /api/sessions/S1/open-note"));
  });

  it("hides Open note without a note file", async () => {
    api(sessionFixture({ hasNote: false }));
    renderAt("/sessions/S1");
    await screen.findByRole("heading", { level: 1 });
    expect(screen.queryByRole("button", { name: "Open note" })).toBeNull();
  });

  it("says so when the note file can't be opened", async () => {
    api(sessionFixture(), {
      "POST /api/sessions/S1/open-note": {
        status: 404,
        body: { error: "no_note", message: "This session has no Markdown note yet." },
      },
    });
    renderAt("/sessions/S1");
    fireEvent.click(await screen.findByRole("button", { name: "Open note" }));
    expect((await screen.findByRole("alert")).textContent).toContain("This session has no Markdown note yet.");
  });

  it("shows a progress bar while transcribing, follows events and hides when it is done", async () => {
    let record = sessionFixture({ status: "transcribing", progress: 0.2, hasNote: false, hasAnalysis: false });
    api(record, { "/api/sessions/S1": () => record });
    renderAt("/sessions/S1");
    const bar = await screen.findByRole("progressbar", { name: "Transcription progress" });
    expect(bar.getAttribute("aria-valuenow")).toBe("20");
    act(() => FakeEventSource.latest().emit("progress", { sessionID: "S1", value: 0.65 }));
    await waitFor(() =>
      expect(screen.getByRole("progressbar").getAttribute("aria-valuenow")).toBe("65"),
    );
    record = { ...record, status: "transcribed", progress: undefined };
    act(() => FakeEventSource.latest().emit("sessionChanged", { id: "S1" }));
    await waitFor(() => expect(screen.queryByRole("progressbar")).toBeNull());
  });

  it("shows no progress bar for a finished session", async () => {
    api();
    renderAt("/sessions/S1");
    await screen.findByRole("heading", { level: 1 });
    expect(screen.queryByRole("progressbar")).toBeNull();
  });
});
