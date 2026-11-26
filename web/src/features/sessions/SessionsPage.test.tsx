import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { mockApi } from "../../test/api";
import { sessionFixture } from "../../test/fixtures";
import { renderAt } from "../../test/render";

vi.mock("wavesurfer.js", () => ({
  default: { create: vi.fn(() => ({ destroy: vi.fn(), on: vi.fn(() => () => {}) })) },
}));

const system = { online: true, recording: false, version: "1.0" };

describe("SessionsPage", () => {
  it("renders SignInAgain when the server answers SignInRequired", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 401 })));
    renderAt("/sessions");
    expect(
      await screen.findByText("Open CallCapture from the menu bar to sign in again."),
    ).toBeTruthy();
  });

  it("lists every session with its state", async () => {
    mockApi({
      "/api/system": system,
      "/api/sessions": [
        sessionFixture(),
        sessionFixture({ id: "S2", title: "Voice memo, pricing idea", status: "completed" }),
      ],
    });
    renderAt("/sessions");
    const list = await screen.findByRole("navigation", { name: "Sessions" });
    const first = await within(list).findByRole("link", { name: /Weekly sync, release plan/ });
    expect(first.getAttribute("href")).toBe("/sessions/S1");
    expect(within(list).getByText("waiting")).toBeTruthy();
    expect(screen.getByText("Choose a session on the left.")).toBeTruthy();
  });

  it("shows search hits with the matching words marked, linked to the moment", async () => {
    const fetchFn = mockApi({
      "/api/system": system,
      "/api/sessions": [sessionFixture()],
      "/api/search": (_init, url) =>
        url.searchParams.get("q") === "rollback"
          ? [
              {
                id: "S1#0",
                sessionId: "S1",
                title: "Weekly sync, release plan",
                time: 910,
                excerpt: "Olena: we still need someone to own the rollback plan.",
              },
              { id: "S1#1", sessionId: "S1", title: "Weekly sync, release plan", excerpt: "Rollback notes" },
            ]
          : [],
    });
    renderAt("/sessions");
    fireEvent.change(await screen.findByRole("searchbox", { name: "Search everything you recorded" }), {
      target: { value: "rollback" },
    });
    expect(await screen.findByText("2 moments match “rollback”")).toBeTruthy();
    const timed = screen.getByRole("link", { name: /15:10/ });
    expect(timed.getAttribute("href")).toBe("/sessions/S1?tab=transcript&t=910");
    expect(within(timed).getByText("rollback").tagName).toBe("MARK");
    const untimed = screen.getByRole("link", { name: /Rollback notes/ });
    expect(untimed.getAttribute("href")).toBe("/sessions/S1");
    await waitFor(() =>
      expect(fetchFn.mock.calls.some(([u]) => String(u) === "/api/search?q=rollback")).toBe(true),
    );
  });

  it("redirects / to /sessions and shows Not found for unknown routes", async () => {
    mockApi({ "/api/system": system, "/api/sessions": [] });
    const { router } = renderAt("/");
    await waitFor(() => expect(router.state.location.pathname).toBe("/sessions"));
    expect(await screen.findByText("Nothing recorded yet. Record a call from the menu bar.")).toBeTruthy();

    await router.navigate("/nope");
    expect(await screen.findByRole("heading", { name: "Not found" })).toBeTruthy();
    expect(screen.getByRole("link", { name: "Back to sessions" }).getAttribute("href")).toBe("/sessions");
  });
});
