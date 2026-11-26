import { describe, expect, it } from "vitest";
import { catalogModel } from "./testData";
import { DEFAULT_SORT, perHour, scoreSegments, sortModels, toggleSort, visibleModels } from "./modelSort";

const models = [
  catalogModel({ id: "smart/json", name: "Smart JSON", live: 6.3, final: 0.08, scores: { intelligence: 70 } }),
  catalogModel({ id: "text/only", name: "Text Only", live: 0.05, final: 0.001, json: false }),
  catalogModel({ id: "cheap/json", name: "Cheap JSON", live: 0.32, final: 0.004, scores: { intelligence: 40 } }),
  catalogModel({ id: "mid/json", name: "Mid JSON", live: 1.31, final: 0.014 }),
];

describe("model table sorting and filtering", () => {
  it("sorts by the live per-hour cost by default, cheapest first", () => {
    expect(DEFAULT_SORT).toEqual({ column: "live", descending: false });
    expect(sortModels(models, DEFAULT_SORT).map((m) => m.id)).toEqual([
      "text/only",
      "cheap/json",
      "mid/json",
      "smart/json",
    ]);
  });

  it("filters to JSON-capable models when asked, and searches name and id", () => {
    expect(visibleModels(models, { query: "", jsonOnly: true, sort: DEFAULT_SORT }).map((m) => m.id)).toEqual([
      "cheap/json",
      "mid/json",
      "smart/json",
    ]);
    expect(visibleModels(models, { query: "", jsonOnly: false, sort: DEFAULT_SORT })).toHaveLength(4);
    expect(visibleModels(models, { query: "SMART", jsonOnly: true, sort: DEFAULT_SORT }).map((m) => m.id)).toEqual([
      "smart/json",
    ]);
    expect(visibleModels(models, { query: "text/", jsonOnly: false, sort: DEFAULT_SORT }).map((m) => m.id)).toEqual([
      "text/only",
    ]);
  });

  it("puts models without a score below every scored model, whichever way it sorts", () => {
    const best = sortModels(models, { column: "intelligence", descending: true }).map((m) => m.id);
    expect(best.slice(0, 2)).toEqual(["smart/json", "cheap/json"]);
    const worst = sortModels(models, { column: "intelligence", descending: false }).map((m) => m.id);
    expect(worst.slice(0, 2)).toEqual(["cheap/json", "smart/json"]);
  });

  it("toggles direction on the same column and starts scores high-first", () => {
    expect(toggleSort(DEFAULT_SORT, "live")).toEqual({ column: "live", descending: true });
    expect(toggleSort(DEFAULT_SORT, "intelligence")).toEqual({ column: "intelligence", descending: true });
    expect(toggleSort(DEFAULT_SORT, "name")).toEqual({ column: "name", descending: false });
  });

  it("formats per-hour costs like the app", () => {
    expect(perHour(0)).toBe("free");
    expect(perHour(0.0042)).toBe("$0.0042");
    expect(perHour(0.32)).toBe("$0.32");
    expect(perHour(12.6)).toBe("$13");
  });

  it("turns scores into ten bar segments", () => {
    expect(scoreSegments(62, 100)).toBe(6);
    expect(scoreSegments(0.85, 1)).toBe(9);
    expect(scoreSegments(140, 100)).toBe(10);
  });
});
