import { describe, expect, it } from "vitest";
import { isExternalHref } from "./Note";

const base = "http://127.0.0.1:4319/sessions/S1";

describe("isExternalHref", () => {
  it("treats any link that resolves to another origin as external", () => {
    expect(isExternalHref("https://example.com/plan", base)).toBe(true);
    expect(isExternalHref("//evil.example/x", base)).toBe(true);
    expect(isExternalHref("/\\evil.example", base)).toBe(true);
    expect(isExternalHref("mailto:someone@example.com", base)).toBe(true);
  });

  it("keeps same-origin, fragment and empty links inside the app", () => {
    expect(isExternalHref("/sessions/S2", base)).toBe(false);
    expect(isExternalHref("#top", base)).toBe(false);
    expect(isExternalHref("", base)).toBe(false);
    expect(isExternalHref(undefined, base)).toBe(false);
    expect(isExternalHref("http://127.0.0.1:4319/sessions/S3", base)).toBe(false);
  });
});
