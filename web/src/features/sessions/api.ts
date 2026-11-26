import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef } from "react";
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

const POLL_MS = 2_000;

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

/** Recording state, polled every 2 s (also in a hidden window, so playback stops when a recording starts). */
export function useSystem() {
  return useQuery({
    queryKey: keys.system,
    queryFn: () => apiGet<SystemStatus>("/api/system"),
    refetchInterval: POLL_MS,
    refetchIntervalInBackground: true,
  });
}

/** Statuses that change on their own (capture or processing running), so they are polled. */
const isChanging = (status: string | undefined): boolean => status === "recording" || status === "transcribing";

/** Every session, newest first; polled every 2 s while any of them records or is processed. */
export function useSessions() {
  return useQuery({
    queryKey: keys.sessions,
    queryFn: () => apiGet<SessionDTO[]>("/api/sessions"),
    refetchInterval: (query) => (query.state.data?.some((s) => isChanging(s.status)) ? POLL_MS : false),
  });
}

/** A recording starting or stopping adds or updates a row: refetch the list when the flag flips. */
export function useRefreshOnRecordingChange() {
  const client = useQueryClient();
  const recording = useSystem().data?.recording;
  const previous = useRef<boolean | undefined>(undefined);
  useEffect(() => {
    if (recording === undefined) return;
    const was = previous.current;
    previous.current = recording;
    if (was !== undefined && was !== recording) void client.invalidateQueries({ queryKey: keys.sessions });
  }, [client, recording]);
}

export function useSearch(query: string) {
  const q = query.trim();
  return useQuery({
    queryKey: keys.search(q),
    queryFn: () => apiGet<SearchHit[]>(`/api/search?q=${encodeURIComponent(q)}`),
    enabled: q.length >= 2,
  });
}

/** The session record; polled every 2 s while it records or is being processed. */
export function useSession(id: string) {
  return useQuery({
    queryKey: keys.session(id),
    queryFn: () => apiGet<SessionDTO>(sessionPath(id)),
    refetchInterval: (query) => (isChanging(query.state.data?.status) ? POLL_MS : false),
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

/** When a recording or a processing run ends, refetch everything it may have changed. */
export function useRefreshAfterProcessing(session: SessionDTO | undefined) {
  const client = useQueryClient();
  const previous = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (!session) return;
    const was = previous.current;
    previous.current = session.status;
    if (isChanging(was) && session.status !== was) {
      void client.invalidateQueries({ queryKey: keys.session(session.id) });
      void client.invalidateQueries({ queryKey: keys.sessions });
      void client.invalidateQueries({ queryKey: ["search"] });
    }
  }, [client, session]);
}

export function useReprocess(id: string) {
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => apiSend<{ started: boolean }>("POST", `${sessionPath(id)}/reprocess`),
    // The server marks the record "transcribing" before answering 202; refetch to start polling.
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
