import { describe, expect, it } from "vitest";
import { highlightParts } from "./highlight";

describe("highlightParts", () => {
  it("marks every case-insensitive match of the query", () => {
    expect(highlightParts("Rollback: the rollback took", "ROLLBACK")).toEqual([
      { text: "Rollback", hit: true },
      { text: ": the ", hit: false },
      { text: "rollback", hit: true },
      { text: " took", hit: false },
    ]);
  });

  it("ignores diacritics like the server search does", () => {
    expect(highlightParts("Meet at the café", "cafe")).toEqual([
      { text: "Meet at the ", hit: false },
      { text: "café", hit: true },
    ]);
  });

  it("treats the query as text, not a pattern", () => {
    expect(highlightParts("a+b and ab", "a+b")).toEqual([
      { text: "a+b", hit: true },
      { text: " and ab", hit: false },
    ]);
  });

  it("returns the text unmarked when nothing matches or the query is blank", () => {
    expect(highlightParts("Weekly sync", "26.11")).toEqual([{ text: "Weekly sync", hit: false }]);
    expect(highlightParts("Weekly sync", "  ")).toEqual([{ text: "Weekly sync", hit: false }]);
  });
});
