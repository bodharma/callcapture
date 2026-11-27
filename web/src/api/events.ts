import { useSyncExternalStore } from "react";
import { apiGet, SignInRequired } from "./client";
import type { LiveNotesUsage, LiveSource, LiveTurn } from "./liveTypes";
import type { RecordingButtonState } from "./types";

/** The app's recording phase, from its state and any start or stop in progress. */
export type RecordingState = "idle" | "starting" | "recording" | "stopping" | "processing";

interface RecordingFields {
  /** Playback would be recorded (reported on its own: true after a failed stop too). */
  blocked: boolean;
  button: RecordingButtonState;
  problem?: string;
}

/** One frame of `GET /api/events`, by its SSE event name (see the Swift `ServerEvent`). */
export type ServerEvent =
  | ({ type: "hello"; recording: RecordingState; online: boolean } & RecordingFields)
  | ({ type: "recording"; state: RecordingState } & RecordingFields)
  | { type: "liveDocument"; sessionID: string }
  | { type: "liveTurn"; turn: LiveTurn }
  | { type: "partial"; source: LiveSource; text: string }
  | { type: "spend"; usage: LiveNotesUsage }
  | { type: "connectivity"; online: boolean }
  | { type: "sessionChanged"; id: string }
  | { type: "catalog" }
  | { type: "settings" };

export type Connection = "connecting" | "live" | "reconnecting" | "signedOut";

/** "ok" to keep reconnecting; "signedOut" when the app wants a new sign-in (401). */
export type ProbeResult = "ok" | "signedOut";

export interface EventStreamOptions {
  onEvent: (event: ServerEvent) => void;
  onConnection: (state: Connection) => void;
  /** Asked after every drop: EventSource can't see the status code, so this tells a 401 apart. */
  probe: () => Promise<ProbeResult>;
  url?: string;
}

const EVENT_NAMES: readonly ServerEvent["type"][] = [
  "hello",
  "recording",
  "liveDocument",
  "liveTurn",
  "partial",
  "spend",
  "connectivity",
  "sessionChanged",
  "catalog",
  "settings",
];
const FIRST_RETRY_MS = 1_000;
const MAX_RETRY_MS = 30_000;

function toEvent(type: ServerEvent["type"], data: unknown): ServerEvent | undefined {
  if (!data || typeof data !== "object") return undefined;
  if (type === "liveTurn") return { type, turn: data as LiveTurn };
  if (type === "spend") return { type, usage: data as LiveNotesUsage };
  return { ...(data as object), type } as ServerEvent;
}

/**
 * One events connection that reconnects itself: on any error it closes the
 * EventSource (so the browser's own fixed-delay retry doesn't run), asks `probe`
 * whether the session is still valid, then retries after 1 s, 2 s, 4 s … up to 30 s.
 * A connection that opens resets the delay. `probe` saying "signedOut" stops it.
 */
export function openEventStream({ onEvent, onConnection, probe, url = "/api/events" }: EventStreamOptions): {
  close(): void;
} {
  let source: EventSource | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let delay = FIRST_RETRY_MS;
  let closed = false;

  const connect = () => {
    timer = undefined;
    if (closed) return;
    const current = new EventSource(url);
    source = current;
    current.onopen = () => {
      if (closed || source !== current) return;
      delay = FIRST_RETRY_MS;
      onConnection("live");
    };
    current.onerror = () => {
      if (closed || source !== current) return;
      current.close();
      source = undefined;
      onConnection("reconnecting");
      void probe()
        .catch((): ProbeResult => "ok")
        .then((result) => {
          if (closed) return;
          if (result === "signedOut") {
            closed = true;
            onConnection("signedOut");
            return;
          }
          timer = setTimeout(connect, delay);
          delay = Math.min(delay * 2, MAX_RETRY_MS);
        });
    };
    for (const name of EVENT_NAMES) {
      current.addEventListener(name, (message: MessageEvent) => {
        let data: unknown;
        try {
          data = JSON.parse(String(message.data));
        } catch {
          return; // A damaged frame is skipped; the next refetch corrects anything it carried.
        }
        const event = toEvent(name, data);
        if (event && !closed) onEvent(event);
      });
    }
  };

  onConnection("connecting");
  connect();
  return {
    close() {
      closed = true;
      if (timer !== undefined) clearTimeout(timer);
      source?.close();
      source = undefined;
    },
  };
}

// One shared connection per page, opened by the first subscriber and closed with the last.

const listeners = new Set<(event: ServerEvent) => void>();
const connectionListeners = new Set<() => void>();
let connection: Connection = "connecting";
let shared: { close(): void } | undefined;

function setConnection(state: Connection) {
  if (state === connection) return;
  connection = state;
  for (const listener of connectionListeners) listener();
}

async function defaultProbe(): Promise<ProbeResult> {
  try {
    await apiGet("/api/system");
    return "ok";
  } catch (error) {
    return error instanceof SignInRequired ? "signedOut" : "ok";
  }
}

export interface SubscribeOptions {
  /** Replaces the default `/api/system` check (the app routes it through its query cache). */
  probe?: () => Promise<ProbeResult>;
}

/** Listens to the app's events; returns the unsubscribe function. */
export function subscribe(onEvent: (event: ServerEvent) => void, options: SubscribeOptions = {}): () => void {
  listeners.add(onEvent);
  if (!shared) {
    shared = openEventStream({
      onEvent: (event) => {
        for (const listener of [...listeners]) listener(event);
      },
      onConnection: setConnection,
      probe: options.probe ?? defaultProbe,
    });
  }
  return () => {
    listeners.delete(onEvent);
    if (listeners.size === 0 && shared) {
      shared.close();
      shared = undefined;
      setConnection("connecting");
    }
  };
}

export function getConnection(): Connection {
  return connection;
}

export function onConnectionChange(listener: () => void): () => void {
  connectionListeners.add(listener);
  return () => connectionListeners.delete(listener);
}

/** The shared connection's state, for the small status text in the top bar. */
export function useConnection(): Connection {
  return useSyncExternalStore(onConnectionChange, getConnection, getConnection);
}
