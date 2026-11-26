import { useSyncExternalStore } from "react";
import { useSearchParams } from "react-router";

/** The floating panel is at most 480 px wide. */
const NARROW = "(max-width: 480px)";

function narrowQuery(): MediaQueryList | undefined {
  return typeof window.matchMedia === "function" ? window.matchMedia(NARROW) : undefined;
}

function subscribe(onChange: () => void): () => void {
  const query = narrowQuery();
  query?.addEventListener("change", onChange);
  return () => query?.removeEventListener("change", onChange);
}

/** The compact live layout: asked for with `?compact=1` (the panel), or any window ≤ 480 px. */
export function useCompact(): boolean {
  const [params] = useSearchParams();
  const narrow = useSyncExternalStore(
    subscribe,
    () => narrowQuery()?.matches ?? false,
    () => false,
  );
  return params.get("compact") === "1" || narrow;
}
