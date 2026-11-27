import type { QueryClient } from "@tanstack/react-query";
import type { RecordingState, ServerEvent } from "../api/events";
import type { LiveSnapshot } from "../api/liveTypes";
import type { RecordingButtonState, SessionDTO, SystemStatus } from "../api/types";
import { liveKeys } from "../features/live/api";
import { invalidateSession, keys } from "../features/sessions/api";
import { settingsKeys } from "../features/settings/api";

interface RecordingChange {
  recordingState: RecordingState;
  blocked: boolean;
  button: RecordingButtonState;
  problem?: string;
}

interface SystemChange {
  online?: boolean;
  recording?: RecordingChange;
}

/** Writes event state into the cached `/api/system` answer; fetches it if none is cached yet. */
function updateSystem(client: QueryClient, change: SystemChange) {
  const current = client.getQueryData<SystemStatus>(keys.system);
  if (!current) {
    void client.invalidateQueries({ queryKey: keys.system });
    return;
  }
  const recording = change.recording;
  const next: SystemStatus = recording
    ? {
        ...current,
        recording: recording.blocked,
        recordingState: recording.recordingState,
        button: recording.button,
        problem: recording.problem,
      }
    : { ...current };
  if (change.online !== undefined) next.online = change.online;
  client.setQueryData<SystemStatus>(keys.system, next);
}

/**
 * Refetches open session details (["session", id] only, not their transcripts or
 * peaks): what can run now (re-process, delete) depends on the network, the
 * configured engine, and whether the app is recording or processing.
 */
function invalidateSessionDetails(client: QueryClient) {
  void client.invalidateQueries({
    predicate: (query) => query.queryKey.length === 2 && query.queryKey[0] === keys.session("")[0],
  });
}

/** Applies `change` to the cached live view, if it is the meeting being shown. */
function updateLive(client: QueryClient, change: (live: LiveSnapshot) => LiveSnapshot) {
  client.setQueryData<LiveSnapshot | { active: false }>(liveKeys.current, (live) =>
    live && "topics" in live ? change(live) : live,
  );
}

/**
 * Turns one server event into query-cache updates: small state is written in
 * place, anything else is invalidated so open views refetch it. `resync` is true
 * for a `hello` after a dropped connection, when events may have been missed.
 */
export function applyEvent(client: QueryClient, event: ServerEvent, resync: boolean) {
  switch (event.type) {
    case "hello":
      updateSystem(client, {
        online: event.online,
        recording: { recordingState: event.recording, blocked: event.blocked, button: event.button, problem: event.problem },
      });
      if (resync) void client.invalidateQueries();
      return;
    case "recording":
      updateSystem(client, {
        recording: { recordingState: event.state, blocked: event.blocked, button: event.button, problem: event.problem },
      });
      // A start adds a row and a stop finalizes it.
      void client.invalidateQueries({ queryKey: keys.sessions });
      // A recording or a processing run starting or ending changes what an open page may run.
      invalidateSessionDetails(client);
      return;
    case "connectivity":
      updateSystem(client, { online: event.online });
      invalidateSessionDetails(client);
      return;
    case "sessionChanged":
      void invalidateSession(client, event.id);
      void client.invalidateQueries({ queryKey: keys.sessions });
      void client.invalidateQueries({ queryKey: ["search"] });
      return;
    case "liveDocument":
      void client.invalidateQueries({ queryKey: liveKeys.current });
      void client.invalidateQueries({ queryKey: liveKeys.saved(event.sessionID) });
      return;
    case "liveTurn":
      updateLive(client, (live) =>
        live.turns.some((turn) => turn.id === event.turn.id)
          ? live
          : {
              ...live,
              turns: [...live.turns, event.turn].sort((a, b) => a.start - b.start),
              partials: { ...live.partials, [event.turn.source]: undefined },
            },
      );
      return;
    case "partial":
      updateLive(client, (live) => ({ ...live, partials: { ...live.partials, [event.source]: event.text } }));
      return;
    case "spend":
      updateLive(client, (live) => ({ ...live, usage: event.usage }));
      return;
    case "catalog":
      void client.invalidateQueries({ queryKey: settingsKeys.catalog });
      return;
    case "settings":
      void client.invalidateQueries({ queryKey: settingsKeys.settings });
      invalidateSessionDetails(client);
      return;
    case "progress":
      // Written in place: a refetch four times a second would be wasteful.
      client.setQueryData<SessionDTO>(keys.session(event.sessionID), (session) =>
        session && session.status === "transcribing" ? { ...session, progress: event.value } : session,
      );
      return;
  }
}
