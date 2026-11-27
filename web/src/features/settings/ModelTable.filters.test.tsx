import { fireEvent, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { mockApi } from "../../test/api";
import { renderAt } from "../../test/render";
import { catalogFixture, catalogModel, settingsFixture } from "./testData";
import type { CatalogDTO } from "./types";

function open(catalog: CatalogDTO = catalogFixture()) {
  mockApi({
    "/api/system": { online: true, recording: false, version: "1.0" },
    "/api/settings": settingsFixture(),
    "/api/catalog": catalog,
    "POST /api/catalog/refresh": catalog,
  });
  return renderAt("/settings/ai-notes");
}

async function table() {
  return screen.findByRole("table", { name: "OpenRouter models" });
}

function names(): string[] {
  const rows = within(screen.getByRole("table", { name: "OpenRouter models" })).getAllByRole("row").slice(1);
  return rows.map((row) => (within(row).getAllByRole("cell")[0].textContent ?? "").split(" live")[0].split(" final")[0]);
}

const select = (name: string) => screen.getByRole("combobox", { name }) as HTMLSelectElement;
const choose = (name: string, value: string) => fireEvent.change(select(name), { target: { value } });
const tick = (group: string, name: string) =>
  fireEvent.click(within(screen.getByRole("group", { name: group })).getByRole("checkbox", { name }));

describe("model table filters", () => {
  it("labels every control and shows the count, with JSON-capable models only by default", async () => {
    open();
    await table();
    expect(screen.getByRole("group", { name: "Provider" })).toBeTruthy();
    expect(screen.getByRole("group", { name: "Good for" })).toBeTruthy();
    for (const name of ["Max cost per hour", "Cost for", "Ukrainian quality", "Context length"]) {
      expect(select(name)).toBeTruthy();
    }
    expect(screen.getByRole("checkbox", { name: "Include models without a score" })).toBeTruthy();
    expect(screen.getByText("Showing 3 of 4 models")).toBeTruthy();
  });

  it("filters by provider", async () => {
    open();
    await table();
    tick("Provider", "google");
    expect(names()).toEqual(["Gemini 2.5 Flash"]);
    expect(screen.getByText("Showing 1 of 4 models")).toBeTruthy();
  });

  it("filters by max cost for the chosen role", async () => {
    open();
    await table();
    choose("Max cost per hour", "1");
    expect(names()).toEqual(["Claude Haiku 5.5"]);
    choose("Cost for", "final");
    expect(names()).toEqual(["Claude Haiku 5.5", "Gemini 2.5 Flash", "Claude Sonnet 5.5"]);
  });

  it("filters by Ukrainian quality, and keeps unscored models on request", async () => {
    open();
    await table();
    choose("Ukrainian quality", "0.8");
    expect(names()).toEqual(["Claude Sonnet 5.5"]);
    fireEvent.click(screen.getByRole("checkbox", { name: "Include models without a score" }));
    expect(names()).toEqual(["Gemini 2.5 Flash", "Claude Sonnet 5.5"]);
  });

  it("filters by context length and by Good for", async () => {
    open();
    await table();
    choose("Context length", "200000");
    expect(names()).toEqual([]);
    choose("Context length", "");
    tick("Good for", "Budget");
    expect(names()).toEqual(["Claude Haiku 5.5"]);
  });

  it("combines with search and the JSON toggle", async () => {
    open();
    await table();
    tick("Provider", "anthropic");
    fireEvent.change(screen.getByRole("searchbox", { name: "Search models" }), { target: { value: "sonnet" } });
    expect(names()).toEqual(["Claude Sonnet 5.5"]);
  });

  it("shows an empty state with Clear filters, which restores the list", async () => {
    open();
    await table();
    tick("Provider", "google");
    tick("Good for", "Budget");
    expect(names()).toEqual([]);
    expect(screen.getByText("No models match these filters.")).toBeTruthy();
    expect(screen.getByText("Showing 0 of 4 models")).toBeTruthy();
    const empty = screen.getByText("No models match these filters.").parentElement!;
    fireEvent.click(within(empty).getByRole("button", { name: "Clear filters" }));
    expect(names()).toHaveLength(3);
    expect(screen.queryByText("No models match these filters.")).toBeNull();
    expect(select("Max cost per hour").value).toBe("");
  });

  it("disables the toolbar Clear filters until a filter is set", async () => {
    open();
    await table();
    const clear = screen.getByRole("button", { name: "Clear filters" }) as HTMLButtonElement;
    expect(clear.disabled).toBe(true);
    choose("Context length", "32000");
    expect(clear.disabled).toBe(false);
    fireEvent.click(clear);
    expect(select("Context length").value).toBe("");
  });

  it("keeps the attribution visible while the Ukrainian quality filter is active", async () => {
    open(catalogFixture({ models: [catalogModel({ id: "a/b", name: "Plain", live: 1, final: 1 })] }));
    await table();
    const attribution = catalogFixture().attribution!;
    expect(screen.queryByText(attribution)).toBeNull();
    choose("Ukrainian quality", "0.7");
    expect(screen.getByText(attribution)).toBeTruthy();
  });
});
