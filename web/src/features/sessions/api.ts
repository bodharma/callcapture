import { type QueryClient, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiGet, apiSend } from "../../api/client";
import type {
  AnalysisDTO,
  NoteDTO,
  SearchHit,
  SessionDTO,
  SpeakerDTO,
  SystemStatus,
  TapeMarker,
  TranscriptLine,
} from "../../api/types";

/** Query keys. Everything about one session sits under ["session", id] so it can be invalidated at once. */
export const keys = {
  system: ["system"] as const,
  sessions: ["sessions"] as const,
  search: (query: string) => ["search", query] as const,
  session: (id: string) => ["session", id] as const,
  part: (id: string, part: SessionPart) => ["session", id, part] as const,
};

export const sessionPath = (id: string): string => `/api/sessions/${encodeURIComponent(id)}`;

interface PartTypes {
  transcript: TranscriptLine[];
  note: NoteDTO;
  analysis: AnalysisDTO | null;
  speakers: SpeakerDTO[];
  peaks: number[];
  markers: TapeMarker[];
}
export type SessionPart = keyof PartTypes;

/**
 * Recording state, network and version. Kept current by the events stream
 * (`hello`, `recording`, `connectivity`); refetched on window focus as a safety net.
 */
export function useSystem() {
  return useQuery({
    queryKey: keys.system,
    queryFn: () => apiGet<SystemStatus>("/api/system"),
  });
}

/** Every session, newest first; `sessionChanged` and `recording` events refresh it. */
export function useSessions() {
  return useQuery({
    queryKey: keys.sessions,
    queryFn: () => apiGet<SessionDTO[]>("/api/sessions"),
  });
}

export function useSearch(query: string) {
  const q = query.trim();
  return useQuery({
    queryKey: keys.search(q),
    queryFn: () => apiGet<SearchHit[]>(`/api/search?q=${encodeURIComponent(q)}`),
    enabled: q.length >= 2,
  });
}

/** The session record; `sessionChanged` events refresh it (status, warnings, errors, files). */
export function useSession(id: string) {
  return useQuery({
    queryKey: keys.session(id),
    queryFn: () => apiGet<SessionDTO>(sessionPath(id)),
  });
}

export function useSessionPart<P extends SessionPart>(id: string, part: P, enabled = true) {
  return useQuery({
    queryKey: keys.part(id, part),
    queryFn: () => apiGet<PartTypes[P]>(`${sessionPath(id)}/${part}`),
    enabled,
    // The audio of a finished session never changes, so neither do its peaks.
    ...(part === "peaks" ? { staleTime: Number.POSITIVE_INFINITY } : {}),
  });
}

/**
 * Refetches a session and everything shown about it (transcript, note, analysis,
 * names, markers), except its peaks: the audio of a stored session never changes.
 */
export function invalidateSession(client: QueryClient, id: string): Promise<void> {
  return client.invalidateQueries({
    queryKey: keys.session(id),
    predicate: (query) => query.queryKey[2] !== "peaks",
  });
}

export function useReprocess(id: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => apiSend<{ started: boolean }>("POST", `${sessionPath(id)}/reprocess`),
    // The server marks the record "transcribing" before answering 202; later changes arrive as events.
    onSuccess: () =>
      Promise.all([
        client.invalidateQueries({ queryKey: keys.session(id), exact: true }),
        client.invalidateQueries({ queryKey: keys.sessions }),
      ]),
  });
}

export function useSaveToVault(id: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => apiSend<{ path: string }>("POST", `${sessionPath(id)}/vault`),
    onSuccess: () => client.invalidateQueries({ queryKey: keys.session(id), exact: true }),
  });
}

export function useReveal(id: string) {
  return useMutation({ mutationFn: () => apiSend<void>("POST", `${sessionPath(id)}/reveal`) });
}

export function useDeleteSession(id: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => apiSend<void>("DELETE", sessionPath(id)),
    onSuccess: () => {
      client.setQueryData<SessionDTO[]>(keys.sessions, (list) => list?.filter((s) => s.id !== id));
      void client.invalidateQueries({ queryKey: keys.sessions });
      void client.invalidateQueries({ queryKey: ["search"] });
    },
  });
}

/** Call after leaving the deleted session's page, so nothing refetches a 404. */
export function forgetSession(client: ReturnType<typeof useQueryClient>, id: string) {
  client.removeQueries({ queryKey: keys.session(id) });
}

export function useRenameSpeaker(id: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: ({ label, name }: { label: string; name: string }) =>
      apiSend<void>("PUT", `${sessionPath(id)}/speakers/${encodeURIComponent(label)}`, { name }),
    // Names are applied to the transcript, note, analysis, speakers and search.
    onSuccess: () =>
      Promise.all([
        client.invalidateQueries({
          queryKey: keys.session(id),
          predicate: (query) => query.queryKey.length === 3 && query.queryKey[2] !== "peaks",
        }),
        client.invalidateQueries({ queryKey: ["search"] }),
      ]),
  });
}
