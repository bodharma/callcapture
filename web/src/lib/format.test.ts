import { describe, expect, it } from "vitest";
import * as format from "./format";

describe("format", () => {
  it("timecode shows h:mm:ss past an hour and mm:ss below", () => {
    expect(format.timecode(3725)).toBe("1:02:05");
    expect(format.timecode(910)).toBe("15:10");
    expect(format.timecode(59.9)).toBe("00:59");
    expect(format.timecode(0)).toBe("00:00");
    expect(format.timecode(Number.NaN)).toBe("00:00");
    expect(format.timecode(-3)).toBe("00:00");
  });

  it("usd keeps sub-cent precision and at least two decimals", () => {
    expect(format.usd(0.0042)).toBe("$0.0042");
    expect(format.usd(0.12)).toBe("$0.12");
    expect(format.usd(0.1234)).toBe("$0.1234");
    expect(format.usd(1.5)).toBe("$1.50");
    expect(format.usd(0)).toBe("$0.00");
  });

  it("length reads in seconds, minutes or hours", () => {
    expect(format.length(45)).toBe("45 s");
    expect(format.length(2772)).toBe("46 min");
    expect(format.length(4320)).toBe("1 h 12 min");
    expect(format.length(3600)).toBe("1 h");
  });

  it("recordedAt and shortDate match the canvas", () => {
    const date = new Date(2026, 10, 26, 10, 0);
    expect(format.recordedAt(date)).toBe("Thu 26 Nov, 10:00");
    expect(format.shortDate(new Date(2026, 10, 5))).toBe("05.11");
  });

  it("languageName names codes and auto-detect", () => {
    expect(format.languageName("uk")).toBe("Ukrainian");
    expect(format.languageName("en")).toBe("English");
    expect(format.languageName("auto")).toBe("Auto-detect");
    expect(format.languageName("")).toBe("Auto-detect");
  });

  it("dayGroup buckets sessions by how recent they are", () => {
    const now = new Date(2026, 10, 26, 18, 0); // Thursday
    expect(format.dayGroup(new Date(2026, 10, 26, 9, 0), now)).toBe("Today");
    expect(format.dayGroup(new Date(2026, 10, 25, 23, 0), now)).toBe("Yesterday");
    expect(format.dayGroup(new Date(2026, 10, 23, 12, 0), now)).toBe("Earlier this week");
    expect(format.dayGroup(new Date(2026, 10, 2, 12, 0), now)).toBe("Earlier this month");
    expect(format.dayGroup(new Date(2026, 8, 14, 12, 0), now)).toBe("September 2026");
  });
});
