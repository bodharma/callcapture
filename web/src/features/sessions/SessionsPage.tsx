import { useEffect, useState } from "react";
import { Outlet } from "react-router";
import { useRefreshOnRecordingChange, useSessions, useSystem } from "./api";
import { SessionList } from "./SessionList";
import "./sessions.css";

const SEARCH_DELAY_MS = 250;

function useDebounced(value: string, delay: number): string {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);
  return debounced;
}

/** Recording and offline state from the app, polled every 2 s. */
function SystemState() {
  const system = useSystem();
  if (system.data?.recording) {
    return (
      <span className="system system--rec" role="status">
        <span className="rec-dot" aria-hidden="true" />
        Recording
      </span>
    );
  }
  if (system.data && !system.data.online) {
    return (
      <span className="system system--offline" role="status">
        Offline
      </span>
    );
  }
  return null;
}

/** The archive window: top bar with search, the session list, and the selected session. */
export function SessionsPage() {
  const [query, setQuery] = useState("");
  const debounced = useDebounced(query, SEARCH_DELAY_MS);
  useRefreshOnRecordingChange();

  return (
    <div className="archive">
      <header className="topbar">
        <span className="brand">CallCapture</span>
        <label className="visually-hidden" htmlFor="archive-search">
          Search everything you recorded
        </label>
        <input
          id="archive-search"
          className="search"
          type="search"
          value={query}
          placeholder="Search everything you recorded"
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Escape") setQuery("");
          }}
        />
        <span className="topbar-gap" />
        <SystemState />
      </header>
      <div className="archive-body">
        <SessionList query={debounced} />
        <main className="pane">
          <Outlet />
        </main>
      </div>
    </div>
  );
}

/** `/sessions` with nothing selected. */
export function SessionsIndex() {
  const sessions = useSessions();
  if (!sessions.data) return null;
  return (
    <p className="empty empty--pane">
      {sessions.data.length === 0
        ? "Nothing recorded yet. Record a call from the menu bar."
        : "Choose a session on the left."}
    </p>
  );
}
