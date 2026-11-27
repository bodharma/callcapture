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
const openProviders = () => {
  const button = screen.getByRole("button", { name: /^Provider/ });
  if (button.getAttribute("aria-expanded") !== "true") fireEvent.click(button);
};
const tick = (group: string, name: string) =>
  fireEvent.click(within(screen.getByRole("group", { name: group })).getByRole("checkbox", { name }));

describe("model table filters", () => {
  it("labels every control and shows the count, with JSON-capable models only by default", async () => {
    open();
    await table();
    expect(screen.getByRole("button", { name: "Provider" })).toBeTruthy();
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
    openProviders();
    tick("Provider", "Google");
    expect(names()).toEqual(["Gemini 2.5 Flash"]);
    expect(screen.getByRole("button", { name: "Provider · 1 selected" })).toBeTruthy();
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
    openProviders();
    tick("Provider", "Anthropic");
    fireEvent.change(screen.getByRole("searchbox", { name: "Search models" }), { target: { value: "sonnet" } });
    expect(names()).toEqual(["Claude Sonnet 5.5"]);
  });

  it("shows an empty state with Clear filters, which restores the list", async () => {
    open();
    await table();
    openProviders();
    tick("Provider", "Google");
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

describe("provider filter with the full catalog", () => {
  const many = () =>
    catalogFixture({
      models: [
        ...Array.from({ length: 65 }, (_, i) => catalogModel({ id: `vendor${i}/m`, name: `Vendor ${i} model`, live: 1, final: 1 })),
        catalogModel({ id: "vendor1/n", name: "Vendor 1 second", live: 1, final: 1 }),
        catalogModel({ id: "vendor1/o", name: "Vendor 1 third", live: 1, final: 1 }),
        catalogModel({ id: "openai/a", name: "GPT A", live: 1, final: 1 }),
        catalogModel({ id: "openai/b", name: "GPT B", live: 1, final: 1 }),
        catalogModel({ id: "openai/c", name: "GPT C", live: 1, final: 1 }),
        catalogModel({ id: "texty/only", name: "Texty", live: 1, final: 1, json: false }),
      ],
    });
  const labels = () =>
    within(screen.getByRole("group", { name: "Provider" }))
      .getAllByRole("checkbox")
      .map((box) => box.closest("label")?.textContent ?? "");

  it("stays collapsed until opened, and the button counts the selection", async () => {
    open(many());
    await table();
    const button = screen.getByRole("button", { name: "Provider" });
    expect(button.getAttribute("aria-expanded")).toBe("false");
    expect(screen.queryByRole("group", { name: "Provider" })).toBeNull();
    fireEvent.click(button);
    tick("Provider", "OpenAI");
    tick("Provider", "Vendor1");
    expect(screen.getByRole("button", { name: "Provider · 2 selected" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Select none" }));
    expect(screen.getByRole("button", { name: "Provider" })).toBeTruthy();
  });

  it("orders by model count, shows display names and counts, and falls back to a capitalised id", async () => {
    open(many());
    await table();
    openProviders();
    const shown = labels();
    expect(shown[0]).toBe("OpenAI3");
    expect(shown[1]).toBe("Vendor13");
    expect(shown[2]).toBe("Vendor01");
    expect(shown).toHaveLength(66);
  });

  it("narrows the list with the labelled filter field", async () => {
    open(many());
    await table();
    openProviders();
    fireEvent.change(screen.getByRole("textbox", { name: "Filter providers" }), { target: { value: "open" } });
    expect(labels()).toEqual(["OpenAI3"]);
  });

  it("omits a provider with only non-JSON models while JSON-only is on, and lists it when off", async () => {
    open(many());
    await table();
    openProviders();
    expect(labels().some((l) => l.startsWith("Texty"))).toBe(false);
    fireEvent.click(screen.getByRole("checkbox", { name: "Works for live notes" }));
    expect(labels().some((l) => l.startsWith("Texty"))).toBe(true);
  });

  it("closes on a pointer press outside, leaving focus where the press put it", async () => {
    open(many());
    await table();
    openProviders();
    fireEvent.pointerDown(screen.getByRole("textbox", { name: "Filter providers" }));
    expect(screen.getByRole("group", { name: "Provider" })).toBeTruthy();
    const elsewhere = screen.getByRole("checkbox", { name: "Works for live notes" });
    elsewhere.focus();
    fireEvent.pointerDown(elsewhere);
    expect(screen.getByRole("button", { name: "Provider" }).getAttribute("aria-expanded")).toBe("false");
    expect(document.activeElement).toBe(elsewhere);
  });

  it("closes when focus tabs out of the filter, and stays open while it moves inside", async () => {
    open(many());
    await table();
    openProviders();
    const field = screen.getByRole("textbox", { name: "Filter providers" });
    const inside = screen.getByRole("button", { name: "Select none" });
    fireEvent.focusOut(field, { relatedTarget: inside });
    expect(screen.getByRole("group", { name: "Provider" })).toBeTruthy();
    const outside = screen.getByRole("checkbox", { name: "Include models without a score" });
    fireEvent.focusOut(inside, { relatedTarget: outside });
    expect(screen.queryByRole("group", { name: "Provider" })).toBeNull();
  });

  it("keeps a chosen provider listed, at zero, when JSON-only hides all its models", async () => {
    open(many());
    await table();
    fireEvent.click(screen.getByRole("checkbox", { name: "Works for live notes" }));
    openProviders();
    tick("Provider", "Texty");
    fireEvent.click(screen.getByRole("checkbox", { name: "Works for live notes" }));
    expect(labels().find((l) => l.startsWith("Texty"))).toBe("Texty0");
    tick("Provider", "Texty");
    expect(labels().some((l) => l.startsWith("Texty"))).toBe(false);
  });

  it("closes on Escape and returns focus to the button", async () => {
    open(many());
    await table();
    openProviders();
    const field = screen.getByRole("textbox", { name: "Filter providers" });
    field.focus();
    fireEvent.keyDown(field, { key: "Escape" });
    const button = screen.getByRole("button", { name: "Provider" });
    expect(button.getAttribute("aria-expanded")).toBe("false");
    expect(document.activeElement).toBe(button);
  });
});
