import { act, fireEvent, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { SessionDTO } from "../../api/types";
import { calls, mockApi, type RouteValue } from "../../test/api";
import { FakeEventSource } from "../../test/fakeEventSource";
import { analysisFixture, sessionFixture, transcriptFixture } from "../../test/fixtures";
import { renderAt } from "../../test/render";

vi.mock("wavesurfer.js", () => ({
  default: { create: vi.fn(() => ({ destroy: vi.fn(), on: vi.fn(() => () => {}) })) },
}));

const OFFLINE = "Offline — regenerating AI notes needs an internet connection. A local notes model works offline.";
const OTHER_RUN = "Another session is being processed. Try again when it finishes.";

function api(session: SessionDTO, extra: Record<string, RouteValue> = {}) {
  return mockApi({
    "/api/system": { online: true, recording: false, version: "1.0", recordingState: "idle", button: { action: "start", enabled: true } },
    "/api/sessions": [session],
    [`/api/sessions/${session.id}`]: session,
    [`/api/sessions/${session.id}/transcript`]: transcriptFixture,
    [`/api/sessions/${session.id}/note`]: { markdown: "# Weekly sync" },
    [`/api/sessions/${session.id}/analysis`]: analysisFixture,
    [`/api/sessions/${session.id}/speakers`]: [],
    [`/api/sessions/${session.id}/peaks`]: [0.1, 0.4],
    "/api/sessions/options": { recordingTypes: [], languages: [] },
    ...extra,
  });
}

const regenerateButton = () => screen.findByRole("button", { name: "Regenerate AI notes" }) as Promise<HTMLButtonElement>;

describe("Regenerate AI notes", () => {
  it("sits beside Re-process when the session has a saved transcript", async () => {
    api(sessionFixture());
    renderAt("/sessions/S1");
    const button = await regenerateButton();
    expect(button.disabled).toBe(false);
    const reprocess = screen.getByRole("button", { name: "Re-process" });
    expect(reprocess.nextElementSibling).toBe(button);
  });

  it("isn't offered without a saved transcript", async () => {
    api(sessionFixture({ status: "completed", hasTranscript: false, hasNote: false, hasAnalysis: false }));
    renderAt("/sessions/S1");
    expect(await screen.findByRole("button", { name: "Transcribe" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Regenerate AI notes" })).toBeNull();
  });

  it("is off with the app's reason before any click, and back on when the reason goes", async () => {
    let blocked: string | undefined = OFFLINE;
    const fetchFn = api(sessionFixture(), { "/api/sessions/S1": () => sessionFixture({ regenerateBlocked: blocked }) });
    renderAt("/sessions/S1");
    const button = await regenerateButton();
    expect(button.disabled).toBe(true);
    const shown = screen.getByText(OFFLINE);
    expect(button.getAttribute("aria-describedby")).toBe(shown.id);
    // Re-process has its own rules (a local-transcribed session can still be re-processed).
    expect((screen.getByRole("button", { name: "Re-process" }) as HTMLButtonElement).disabled).toBe(false);

    blocked = undefined;
    act(() => FakeEventSource.latest().emit("connectivity", { online: true }));
    await waitFor(() => expect(screen.queryByText(OFFLINE)).toBeNull());
    expect((await regenerateButton()).disabled).toBe(false);
    expect(calls(fetchFn)).not.toContain("POST /api/sessions/S1/regenerate-notes");
  });

  it("says a shared reason once, for both buttons", async () => {
    api(sessionFixture({ reprocessBlocked: OTHER_RUN, regenerateBlocked: OTHER_RUN }));
    renderAt("/sessions/S1");
    const regenerate = await regenerateButton();
    const reprocess = screen.getByRole("button", { name: "Re-process" });
    const shown = screen.getByText(OTHER_RUN);
    expect(regenerate.getAttribute("aria-describedby")).toBe(shown.id);
    expect(reprocess.getAttribute("aria-describedby")).toBe(shown.id);
  });

  it("starts the run and shows its stage and progress like Re-process", async () => {
    let record = sessionFixture();
    const fetchFn = api(record, {
      "/api/sessions/S1": () => record,
      "POST /api/sessions/S1/regenerate-notes": () => {
        record = sessionFixture({
          status: "transcribing",
          stage: "Regenerating notes",
          progress: 0.3,
          regenerateBlocked: "This session is being processed. Try again when it finishes.",
        });
        return { status: 202, body: { started: true } };
      },
    });
    renderAt("/sessions/S1");
    fireEvent.click(await regenerateButton());

    await waitFor(() => expect(calls(fetchFn)).toContain("POST /api/sessions/S1/regenerate-notes"));
    const bar = await screen.findByRole("progressbar", { name: "Regenerating notes" });
    expect(bar.getAttribute("aria-valuenow")).toBe("30");
    expect(screen.getByText("Regenerating notes. This page updates when it's done.")).toBeTruthy();
    act(() => FakeEventSource.latest().emit("progress", { sessionID: "S1", value: 0.8 }));
    await waitFor(() => expect(screen.getByRole("progressbar").getAttribute("aria-valuenow")).toBe("80"));

    record = sessionFixture({ warning: "AI notes need an LLM API key; rule-based notes were used." });
    act(() => FakeEventSource.latest().emit("sessionChanged", { id: "S1" }));
    await waitFor(() => expect(screen.queryByRole("progressbar")).toBeNull());
    expect(screen.getByText("AI notes need an LLM API key; rule-based notes were used.")).toBeTruthy();
  });

  it("says why when the app refuses to start it", async () => {
    api(sessionFixture(), {
      "POST /api/sessions/S1/regenerate-notes": {
        status: 409,
        body: { error: "no_transcript", message: "This session has no saved transcript yet. Transcribe it first." },
      },
    });
    renderAt("/sessions/S1");
    fireEvent.click(await regenerateButton());
    const alert = await screen.findByRole("alert");
    expect(alert.textContent).toBe(
      "Regenerating AI notes didn't start. This session has no saved transcript yet. Transcribe it first.",
    );
  });
});
