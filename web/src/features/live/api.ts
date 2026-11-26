import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiGet, apiSend } from "../../api/client";
import type { LiveResponse, LiveSnapshot } from "../../api/liveTypes";

/** The meeting being recorded, or a session's saved map. */
export type LiveTarget = { kind: "current" } | { kind: "session"; id: string };

export const currentTarget: LiveTarget = { kind: "current" };

export const liveKeys = {
  current: ["live"] as const,
  saved: (id: string) => ["session", id, "live"] as const,
};

function keyOf(target: LiveTarget) {
  return target.kind === "current" ? liveKeys.current : liveKeys.saved(target.id);
}

/** Where a target's actions go: `/api/live/…` or `/api/sessions/:id/live/…`. */
export function actionBase(target: LiveTarget): string {
  return target.kind === "current" ? "/api/live" : `/api/sessions/${encodeURIComponent(target.id)}/live`;
}

/** The live meeting; `liveDocument`, `liveTurn`, `partial` and `spend` events keep it current. */
export function useLive() {
  return useQuery({
    queryKey: liveKeys.current,
    queryFn: () => apiGet<LiveResponse>("/api/live"),
  });
}

/** A session's saved live map; a `liveDocument` event for that session refreshes it. */
export function useSavedLive(id: string) {
  return useQuery({
    queryKey: liveKeys.saved(id),
    queryFn: () => apiGet<LiveSnapshot>(`/api/sessions/${encodeURIComponent(id)}/live`),
  });
}

export interface LiveRequest {
  /** Below the target's base, e.g. "topics/abc/rename". */
  path: string;
  body?: unknown;
}

/** One live action; each control owns one, so a refusal shows next to that control. */
export function useLiveAction(target: LiveTarget) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: ({ path, body }: LiveRequest) => apiSend<{ path?: string | null }>("POST", `${actionBase(target)}/${path}`, body),
    onSuccess: () => client.invalidateQueries({ queryKey: keyOf(target) }),
  });
}

/** A path segment for a topic or memo id. */
export const seg = (id: string): string => encodeURIComponent(id);
