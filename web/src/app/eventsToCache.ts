import type { QueryClient } from "@tanstack/react-query";
import { blocksPlayback, type RecordingState, type ServerEvent } from "../api/events";
import type { LiveSnapshot } from "../api/liveTypes";
import type { SystemStatus } from "../api/types";
import { liveKeys } from "../features/live/api";
import { invalidateSession, keys } from "../features/sessions/api";
import { settingsKeys } from "../features/settings/api";

interface SystemChange {
  online?: boolean;
  recordingState?: RecordingState;
  problem?: string;
}

/** Writes event state into the cached `/api/system` answer; fetches it if none is cached yet. */
function updateSystem(client: QueryClient, change: SystemChange) {
  const current = client.getQueryData<SystemStatus>(keys.system);
  if (!current) {
    void client.invalidateQueries({ queryKey: keys.system });
    return;
  }
  const next: SystemStatus = { ...current, online: change.online ?? current.online };
  if (change.recordingState !== undefined) {
    next.recordingState = change.recordingState;
    next.recording = blocksPlayback(change.recordingState);
    next.problem = change.problem;
  }
  client.setQueryData<SystemStatus>(keys.system, next);
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
      updateSystem(client, { online: event.online, recordingState: event.recording, problem: event.problem });
      if (resync) void client.invalidateQueries();
      return;
    case "recording":
      updateSystem(client, { recordingState: event.state, problem: event.problem });
      // A start adds a row and a stop finalizes it.
      void client.invalidateQueries({ queryKey: keys.sessions });
      return;
    case "connectivity":
      updateSystem(client, { online: event.online });
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
      return;
  }
}
