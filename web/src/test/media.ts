import { vi } from "vitest";

/**
 * A `matchMedia` that answers `(max-width: Npx)` / `(min-width: Npx)` queries for a
 * window `width` pixels wide; anything else doesn't match.
 */
export function installMatchMedia(width: number) {
  vi.stubGlobal("matchMedia", (query: string) => {
    const max = /max-width:\s*(\d+)px/.exec(query);
    const min = /min-width:\s*(\d+)px/.exec(query);
    const matches = max ? width <= Number(max[1]) : min ? width >= Number(min[1]) : false;
    return {
      matches,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    } satisfies MediaQueryList;
  });
}
