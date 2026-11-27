import type { ReactNode } from "react";
import { NavLink } from "react-router";
import { APP_NOT_ANSWERING } from "../api/client";
import { useConnection } from "../api/events";
import { useSystem } from "../features/sessions/api";
import { RecordControl } from "./RecordControl";
import "./topbar.css";

const CONNECTION_TEXT = {
  connecting: "Connecting…",
  live: "Live",
  reconnecting: "Reconnecting…",
  unreachable: APP_NOT_ANSWERING,
  signedOut: "",
};

/** Whether the app's live updates reach this page. */
export function ConnectionStatus() {
  const connection = useConnection();
  const text = CONNECTION_TEXT[connection];
  if (!text) return null;
  return (
    <span className={`connection connection--${connection}`} role="status">
      {text}
    </span>
  );
}

function OfflineBadge() {
  const online = useSystem().data?.online;
  if (online !== false) return null;
  return (
    <span className="system system--offline" role="status">
      Offline
    </span>
  );
}

const LINKS = [
  { to: "/sessions", label: "Sessions" },
  { to: "/live", label: "Live meeting" },
  { to: "/settings", label: "Settings" },
] as const;

/** The shared top bar: brand, sections, page tools, connection, offline and recording state. */
export function TopBar({ children }: { children?: ReactNode }) {
  return (
    <header className="topbar">
      <span className="brand">CallCapture</span>
      <nav className="topbar-nav" aria-label="Sections">
        {LINKS.map((link) => (
          <NavLink key={link.to} to={link.to} className="topbar-link">
            {link.label}
          </NavLink>
        ))}
      </nav>
      {children}
      <span className="topbar-gap" />
      <ConnectionStatus />
      <OfflineBadge />
      <RecordControl />
    </header>
  );
}
