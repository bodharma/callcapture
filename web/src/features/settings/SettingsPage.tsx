import type { ComponentType } from "react";
import { Link, NavLink, Outlet, useParams } from "react-router";
import { errorText } from "../../api/client";
import "../sessions/sessions.css";
import { useOnline, useSettings } from "./api";
import { AINotesPane } from "./panes/AINotesPane";
import { CostsPane } from "./panes/CostsPane";
import { GeneralPane } from "./panes/GeneralPane";
import type { PaneProps } from "./panes/paneProps";
import { PrivacyPane } from "./panes/PrivacyPane";
import { RecordingPane } from "./panes/RecordingPane";
import { TranscriptionPane } from "./panes/TranscriptionPane";
import { VaultPane } from "./panes/VaultPane";
import "./settings.css";

const PANES: readonly { slug: string; title: string; Pane: ComponentType<PaneProps> }[] = [
  { slug: "general", title: "General", Pane: GeneralPane },
  { slug: "recording", title: "Recording", Pane: RecordingPane },
  { slug: "transcription", title: "Transcription", Pane: TranscriptionPane },
  { slug: "ai-notes", title: "AI notes", Pane: AINotesPane },
  { slug: "privacy", title: "Privacy", Pane: PrivacyPane },
  { slug: "vault", title: "Vault and exports", Pane: VaultPane },
  { slug: "costs", title: "Costs", Pane: CostsPane },
];

/** The settings window: the archive's top bar, the pane list, and the open pane. */
export function SettingsPage() {
  const online = useOnline();
  return (
    <div className="archive">
      <header className="topbar">
        <span className="brand">CallCapture</span>
        <Link className="btn btn--quiet btn--small" to="/sessions">
          Sessions
        </Link>
        <span className="topbar-gap" />
        {online === false && (
          <span className="system system--offline" role="status">
            Offline
          </span>
        )}
      </header>
      <div className="settings-body">
        <nav className="settings-nav" aria-label="Settings">
          {PANES.map((pane) => (
            <NavLink key={pane.slug} to={`/settings/${pane.slug}`} className="settings-link">
              {pane.title}
            </NavLink>
          ))}
        </nav>
        <main className="settings-main">
          <Outlet />
        </main>
      </div>
    </div>
  );
}

/** `/settings/:pane`. */
export function SettingsPaneRoute() {
  const { pane } = useParams();
  const entry = PANES.find((p) => p.slug === pane);
  const settings = useSettings();
  const online = useOnline();
  if (!entry) {
    return (
      <div className="not-found">
        <h1>Not found</h1>
        <p>There is no settings pane at this address.</p>
        <Link to="/settings/general">Open General</Link>
      </div>
    );
  }
  if (!settings.data) {
    return settings.isError ? (
      <p className="field-error" role="alert">
        Settings didn't load. {errorText(settings.error)}
      </p>
    ) : null;
  }
  const { Pane } = entry;
  return <Pane settings={settings.data} online={online} />;
}
