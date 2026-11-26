import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { SessionDTO } from "../../api/types";
import { calls, mockApi, type RouteValue } from "../../test/api";
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
  '<img src="x" onerror="alert(1)">',
  "",
  "![chart](https://tracker.example/pixel.png)",
  "",
  "- [ ] Draft the release notes",
].join("\n");

function api(session: SessionDTO = sessionFixture(), extra: Record<string, RouteValue> = {}) {
  return mockApi({
    "/api/system": { online: true, recording: false, version: "1.0" },
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
    expect(screen.getByText("$0.12")).toBeTruthy();
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

  it("refreshes the page when the session's recording ends", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    let status = "recording";
    api(sessionFixture({ status }), { "/api/sessions/S1": () => sessionFixture({ status }) });
    renderAt("/sessions/S1");
    const waiting = "Still recording. The tape shows up here after you stop.";
    expect(await screen.findByText(waiting)).toBeTruthy();
    status = "completed";
    await vi.advanceTimersByTimeAsync(2_100);
    await waitFor(() => expect(screen.queryByText(waiting)).toBeNull());
    expect(await screen.findByRole("button", { name: "Transcribe" })).toBeTruthy();
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
