import { MutationCache } from "@tanstack/react-query";
import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { calls, mockApi, type RouteValue } from "../../test/api";
import { renderAt } from "../../test/render";
import { catalogFixture, settingsFixture } from "./testData";
import type { SettingsDTO } from "./types";

const online = { online: true, recording: false, version: "1.0" };
const offline = { online: false, recording: false, version: "1.0" };

function bodyOf(fetchFn: ReturnType<typeof mockApi>, call: string): unknown {
  const index = calls(fetchFn).indexOf(call);
  const init = fetchFn.mock.calls[index]?.[1];
  return init?.body ? JSON.parse(String(init.body)) : undefined;
}

function settingsApi(routes: Record<string, RouteValue> = {}, settings: SettingsDTO = settingsFixture()) {
  return mockApi({
    "/api/system": online,
    "/api/settings": settings,
    "/api/catalog": catalogFixture(),
    "POST /api/catalog/refresh": catalogFixture(),
    ...routes,
  });
}

describe("Settings", () => {
  it("opens on General and is reachable from the Sessions top bar", async () => {
    mockApi({ "/api/system": online, "/api/sessions": [], "/api/settings": settingsFixture() });
    const { router } = renderAt("/sessions");
    fireEvent.click(await screen.findByRole("link", { name: "Settings" }));
    expect(await screen.findByRole("heading", { level: 1, name: "General" })).toBeTruthy();
    expect(router.state.location.pathname).toBe("/settings/general");
    const nav = screen.getByRole("navigation", { name: "Settings" });
    for (const pane of ["General", "Recording", "Transcription", "AI notes", "Privacy", "Vault and exports", "Costs"]) {
      expect(within(nav).getByRole("link", { name: pane })).toBeTruthy();
    }
  });

  it("says no API keys are needed when transcription and notes both run on this Mac", async () => {
    const caption = "No API keys required for current configuration.";
    settingsApi({}, settingsFixture((s) => (s.aiNotes.provider = "local")));
    const { unmount } = renderAt("/settings/transcription");
    expect(await screen.findByText(caption)).toBeTruthy();
    unmount();
    settingsApi();
    renderAt("/settings/transcription");
    await screen.findByRole("heading", { level: 1, name: "Transcription" });
    expect(screen.queryByText(caption)).toBeNull();
  });

  it("lists models by live cost per hour, only JSON-capable ones until the filter is cleared", async () => {
    settingsApi();
    renderAt("/settings/ai-notes");
    const table = await screen.findByRole("table", { name: "OpenRouter models" });
    const names = () =>
      within(table)
        .getAllByRole("row")
        .slice(1)
        .map((row) => within(row).getAllByRole("cell")[0].textContent ?? "");
    expect(names().map((n) => n.split(" live")[0].split(" final")[0])).toEqual([
      "Claude Haiku 5.5",
      "Gemini 2.5 Flash",
      "Claude Sonnet 5.5",
    ]);
    const live = within(table).getByRole("columnheader", { name: /Live, per hour/ });
    expect(live.getAttribute("aria-sort")).toBe("ascending");

    fireEvent.click(screen.getByRole("checkbox", { name: "Works for live notes" }));
    expect(names()[0]).toContain("Text Only");
    expect(names()).toHaveLength(4);
  });

  it("shows the benchmark attribution with the scores and the cost per meeting hour for each role", async () => {
    settingsApi();
    renderAt("/settings/ai-notes");
    expect(await screen.findByText(catalogFixture().attribution!)).toBeTruthy();
    const liveCard = screen.getByRole("group", { name: "Live notes" });
    expect(within(liveCard).getByText("Claude Haiku 5.5")).toBeTruthy();
    expect(within(liveCard).getByText("$0.32")).toBeTruthy();
    const finalCard = screen.getByRole("group", { name: "Final notes" });
    expect(within(finalCard).getByText("$0.08")).toBeTruthy();
  });

  it("offline, disables Refresh and Test connection with the app's reasons; picking a model still works", async () => {
    const fetchFn = settingsApi({
      "/api/system": offline,
      "PATCH /api/settings": settingsFixture((s) => (s.aiNotes.liveModel = "google/gemini-2.5-flash")),
    });
    renderAt("/settings/ai-notes");
    await screen.findByRole("table", { name: "OpenRouter models" });
    await waitFor(() => expect(screen.getByRole("button", { name: "Refresh" }).hasAttribute("disabled")).toBe(true));
    expect(screen.getByText("Offline — refreshing needs an internet connection.")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Test connection" }).hasAttribute("disabled")).toBe(true);
    expect(screen.getByText("Offline — testing the key needs internet.")).toBeTruthy();
    expect(calls(fetchFn)).not.toContain("POST /api/catalog/refresh");

    const use = screen.getByRole("button", { name: "Use Gemini 2.5 Flash for live notes" });
    expect(use.hasAttribute("disabled")).toBe(false);
    fireEvent.click(use);
    await waitFor(() => expect(calls(fetchFn)).toContain("PATCH /api/settings"));
    expect(bodyOf(fetchFn, "PATCH /api/settings")).toEqual({ aiNotes: { liveModel: "google/gemini-2.5-flash" } });
  });

  it("shows the app's warning under a model that will not work", async () => {
    settingsApi(
      {},
      settingsFixture((s) => {
        s.aiNotes.liveModel = "text/only";
        s.aiNotes.warnings = { live: "Text Only does not support JSON output, which automatic live notes need." };
      }),
    );
    renderAt("/settings/ai-notes");
    expect(
      await screen.findByText("Text Only does not support JSON output, which automatic live notes need."),
    ).toBeTruthy();
  });

  it("key fields are write-only password inputs, never prefilled and cleared after saving", async () => {
    const fetchFn = settingsApi({ "PUT /api/settings/secrets/openrouter": { status: 204 } });
    renderAt("/settings/ai-notes");
    const input = (await screen.findByLabelText("OpenRouter key")) as HTMLInputElement;
    expect(input.type).toBe("password");
    // Not "off": browsers ignore that on password fields; "new-password" stops autofill of a stored one.
    expect(input.getAttribute("autocomplete")).toBe("new-password");
    expect(input.value).toBe("");
    expect(screen.getByText("Saved in the Keychain.")).toBeTruthy();

    fireEvent.change(input, { target: { value: "sk-or-v1-synthetic" } });
    fireEvent.click(screen.getByRole("button", { name: "Save OpenRouter key" }));
    expect(await screen.findByText("Key saved.")).toBeTruthy();
    expect(input.value).toBe("");
    expect(bodyOf(fetchFn, "PUT /api/settings/secrets/openrouter")).toEqual({ value: "sk-or-v1-synthetic" });
    expect(document.body.textContent).not.toContain("sk-or-v1-synthetic");
  });

  it("keeps no copy of a saved key in the app's mutation state", async () => {
    const build = vi.spyOn(MutationCache.prototype, "build");
    try {
      settingsApi({ "PUT /api/settings/secrets/openrouter": { status: 204 } });
      renderAt("/settings/ai-notes");
      fireEvent.change(await screen.findByLabelText("OpenRouter key"), { target: { value: "sk-or-v1-synthetic" } });
      fireEvent.click(screen.getByRole("button", { name: "Save OpenRouter key" }));
      expect(await screen.findByText("Key saved.")).toBeTruthy();
      const cache = build.mock.contexts[0] as MutationCache;
      await waitFor(() =>
        expect(cache.getAll().map((mutation) => mutation.state.variables)).not.toContain("sk-or-v1-synthetic"),
      );
    } finally {
      build.mockRestore();
    }
  });

  it("clears an old key test result when the key is replaced", async () => {
    settingsApi({
      "PUT /api/settings/secrets/openrouter": { status: 204 },
      "POST /api/settings/secrets/openrouter/test": { ok: true, message: "The key works." },
    });
    renderAt("/settings/ai-notes");
    fireEvent.click(await screen.findByRole("button", { name: "Test connection" }));
    expect(await screen.findByText("The key works.")).toBeTruthy();
    fireEvent.change(screen.getByLabelText("OpenRouter key"), { target: { value: "sk-or-v1-other" } });
    fireEvent.click(screen.getByRole("button", { name: "Save OpenRouter key" }));
    await screen.findByText("Key saved.");
    expect(screen.queryByText("The key works.")).toBeNull();
  });

  it("shows a refused typed folder as a sentence under the field and keeps what was typed", async () => {
    const fetchFn = settingsApi({
      "PATCH /api/settings": {
        status: 400,
        body: {
          error: "invalid",
          key: "recording.outputDirectory",
          message: "The output folder doesn't exist. Choose an existing folder.",
        },
      },
    });
    renderAt("/settings/recording");
    const field = (await screen.findByLabelText("Output folder")) as HTMLInputElement;
    fireEvent.change(field, { target: { value: "/Users/test/Missing" } });
    fireEvent.keyDown(field, { key: "Enter" });
    const alert = await screen.findByRole("alert");
    expect(alert.textContent).toBe("The output folder doesn't exist. Choose an existing folder.");
    expect(field.value).toBe("/Users/test/Missing");
    expect(field.getAttribute("aria-invalid")).toBe("true");
    expect(bodyOf(fetchFn, "PATCH /api/settings")).toEqual({ recording: { outputDirectory: "/Users/test/Missing" } });
  });

  it("Enter retries a refused value once the problem is fixed, and leaving the field doesn't resend it", async () => {
    let attempts = 0;
    const fetchFn = settingsApi({
      "PATCH /api/settings": () => {
        attempts += 1;
        return attempts === 1
          ? {
              status: 400,
              body: { error: "invalid", message: "The output folder doesn't exist. Choose an existing folder." },
            }
          : settingsFixture((s) => (s.recording.outputDirectory = "/Users/test/Recordings"));
      },
    });
    renderAt("/settings/recording");
    const field = (await screen.findByLabelText("Output folder")) as HTMLInputElement;
    fireEvent.change(field, { target: { value: "/Users/test/Recordings" } });
    fireEvent.keyDown(field, { key: "Enter" });
    await screen.findByRole("alert");
    fireEvent.blur(field);
    expect(calls(fetchFn).filter((c) => c === "PATCH /api/settings")).toHaveLength(1);

    // The user creates the folder, then presses Enter again.
    fireEvent.keyDown(field, { key: "Enter" });
    await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
    expect(calls(fetchFn).filter((c) => c === "PATCH /api/settings")).toHaveLength(2);
    expect(field.value).toBe("/Users/test/Recordings");
  });

  it("saves a folder chosen in the app's folder panel; a cancelled pick saves nothing", async () => {
    let answer: string | null = null;
    const fetchFn = settingsApi({
      "POST /api/system/pick-folder": () => ({ path: answer }),
      "PATCH /api/settings": settingsFixture((s) => (s.vault.obsidianVault = "/Users/test/Notes")),
    });
    renderAt("/settings/vault");
    const choose = await screen.findByRole("button", { name: "Choose vault folder" });
    fireEvent.click(choose);
    await waitFor(() => expect(calls(fetchFn)).toContain("POST /api/system/pick-folder"));
    expect(bodyOf(fetchFn, "POST /api/system/pick-folder")).toEqual({ setting: "obsidianVault" });
    expect(calls(fetchFn)).not.toContain("PATCH /api/settings");

    answer = "/Users/test/Notes";
    fireEvent.click(choose);
    await waitFor(() => expect(calls(fetchFn)).toContain("PATCH /api/settings"));
    expect(bodyOf(fetchFn, "PATCH /api/settings")).toEqual({ vault: { obsidianVault: "/Users/test/Notes" } });
    const vault = (await screen.findByLabelText("Obsidian vault")) as HTMLInputElement;
    await waitFor(() => expect(vault.value).toBe("/Users/test/Notes"));
  });

  it("offline, model downloads are disabled with the app's reason", async () => {
    settingsApi({ "/api/system": offline });
    renderAt("/settings/transcription");
    const download = await screen.findByRole("button", { name: "Download emotion model" });
    await waitFor(() => expect(download.hasAttribute("disabled")).toBe(true));
    expect(
      screen.getByText("Offline — downloading needs an internet connection. Downloaded models work offline."),
    ).toBeTruthy();
  });

  it("a toggle saves at once", async () => {
    const fetchFn = settingsApi({
      "PATCH /api/settings": settingsFixture((s) => (s.general.autoProcessOnStop = false)),
    });
    renderAt("/settings/general");
    fireEvent.click(await screen.findByRole("checkbox", { name: "Process recordings when they stop" }));
    await waitFor(() => expect(calls(fetchFn)).toContain("PATCH /api/settings"));
    expect(bodyOf(fetchFn, "PATCH /api/settings")).toEqual({ general: { autoProcessOnStop: false } });
  });
});
