import { describe, expect, it } from "vitest";
import {
  NO_FILTERS,
  filterModels,
  filtersActive,
  modelProvider,
  providerName,
  providersOf,
  tagsOf,
  type ModelFilters,
} from "./modelFilters";
import { catalogModel } from "./testData";
import type { CatalogModel } from "./types";

const withContext = (model: CatalogModel, contextLength: number): CatalogModel => ({ ...model, contextLength });

const models = [
  catalogModel({
    id: "anthropic/haiku",
    name: "Haiku",
    live: 0.32,
    final: 0.004,
    scores: { multilingual: 0.71 },
    tags: ["Budget"],
  }),
  withContext(
    catalogModel({
      id: "anthropic/sonnet",
      name: "Sonnet",
      live: 6.3,
      final: 0.08,
      scores: { multilingual: 0.9 },
      tags: ["Highest quality", "Strong multilingual"],
    }),
    200_000,
  ),
  withContext(catalogModel({ id: "google/flash", name: "Flash", live: 1.31, final: 0.014 }), 1_000_000),
  withContext(catalogModel({ id: "meta/tiny", name: "Tiny", live: 0.01, final: 0.001, tags: ["Budget"] }), 32_000),
];

const ids = (list: readonly CatalogModel[]) => list.map((m) => m.id);
const filter = (change: Partial<ModelFilters>, role: "live" | "final" = "live") =>
  ids(filterModels(models, { ...NO_FILTERS, ...change }, role));

describe("model filters", () => {
  it("derives the provider from the id prefix and lists them sorted", () => {
    expect(modelProvider("anthropic/claude-sonnet-5.5")).toBe("anthropic");
    expect(modelProvider("no-slash")).toBe("no-slash");
    expect(providersOf(models).map((p) => [p.id, p.count])).toEqual([
      ["anthropic", 2],
      ["google", 1],
      ["meta", 1],
    ]);
  });

  it("names known providers and capitalises the first letter of the rest", () => {
    expect(providerName("openai")).toBe("OpenAI");
    expect(providerName("meta-llama")).toBe("Meta Llama");
    expect(providerName("x-ai")).toBe("xAI");
    expect(providerName("moonshotai")).toBe("Moonshotai");
  });

  it("lists the tags the app computed, each once, sorted", () => {
    expect(tagsOf(models)).toEqual(["Budget", "Highest quality", "Strong multilingual"]);
  });

  it("passes everything with no filters", () => {
    expect(filter({})).toHaveLength(4);
    expect(filtersActive(NO_FILTERS)).toBe(false);
  });

  it("filters by provider, several at once", () => {
    expect(filter({ providers: ["google"] })).toEqual(["google/flash"]);
    expect(filter({ providers: ["google", "meta"] })).toEqual(["google/flash", "meta/tiny"]);
  });

  it("filters by the maximum cost per hour for the role being chosen", () => {
    expect(filter({ maxCostPerHour: 1 }, "live")).toEqual(["anthropic/haiku", "meta/tiny"]);
    expect(filter({ maxCostPerHour: 0.01 }, "final")).toEqual(["anthropic/haiku", "meta/tiny"]);
    expect(filter({ maxCostPerHour: 0.32 }, "live")).toContain("anthropic/haiku");
  });

  it("filters by the minimum multilingual score, with or without unscored models", () => {
    expect(filter({ minMultilingual: 0.8 })).toEqual(["anthropic/sonnet"]);
    expect(filter({ minMultilingual: 0.7 })).toEqual(["anthropic/haiku", "anthropic/sonnet"]);
    expect(filter({ minMultilingual: 0.8, includeUnscored: true })).toEqual([
      "anthropic/sonnet",
      "google/flash",
      "meta/tiny",
    ]);
  });

  it("filters by the minimum context length", () => {
    expect(filter({ minContext: 200_000 })).toEqual(["anthropic/sonnet", "google/flash"]);
    expect(filter({ minContext: 1_000_000 })).toEqual(["google/flash"]);
    expect(filter({ minContext: 32_000 })).toHaveLength(4);
  });

  it("filters by the app's tags, matching any chosen", () => {
    expect(filter({ goodFor: ["Budget"] })).toEqual(["anthropic/haiku", "meta/tiny"]);
    expect(filter({ goodFor: ["Highest quality", "Budget"] })).toHaveLength(3);
  });

  it("combines every filter", () => {
    const combined = filter({
      providers: ["anthropic"],
      maxCostPerHour: 1,
      minMultilingual: 0.7,
      minContext: 100_000,
      goodFor: ["Budget"],
    });
    expect(combined).toEqual(["anthropic/haiku"]);
    expect(filter({ providers: ["meta"], minMultilingual: 0.7 })).toEqual([]);
  });

  it("reports whether any filter is set", () => {
    expect(filtersActive({ ...NO_FILTERS, providers: ["google"] })).toBe(true);
    expect(filtersActive({ ...NO_FILTERS, maxCostPerHour: 1 })).toBe(true);
    expect(filtersActive({ ...NO_FILTERS, minMultilingual: 0.7 })).toBe(true);
    expect(filtersActive({ ...NO_FILTERS, minContext: 32_000 })).toBe(true);
    expect(filtersActive({ ...NO_FILTERS, goodFor: ["Budget"] })).toBe(true);
  });
});
