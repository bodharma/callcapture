import { useMutation } from "@tanstack/react-query";
import { apiSend, errorText } from "../api/client";
import { useSystem } from "../features/sessions/api";
import "./topbar.css";

/** The REC mark; the only element with the glitch effect (still under reduced motion). */
export function RecMark() {
  return (
    <span className="rec-mark" aria-hidden="true">
      REC
    </span>
  );
}

interface RecordControlProps {
  /** Smaller button for the floating panel. */
  compact?: boolean;
}

/**
 * Record / Stop for the web UI. The app sends its menu button as it is (action,
 * enabled, reason), so the two can't disagree; events keep it current. Permission
 * prompts appear natively; a refused or failed start is shown as a sentence.
 */
export function RecordControl({ compact = false }: RecordControlProps) {
  const system = useSystem();
  const toggle = useMutation({
    mutationFn: (action: "start" | "stop") => apiSend<{ started: boolean }>("POST", `/api/recording/${action}`),
  });
  const phase = system.data?.recordingState;
  const button = system.data?.button;
  // Nothing to offer until the app has said what its button does.
  if (!phase || !button) return null;

  const capturing = phase === "starting" || phase === "recording" || phase === "stopping";
  const label =
    phase === "starting" ? "Starting…" : phase === "stopping" ? "Stopping…" : button.action === "stop" ? "Stop" : "Record";
  const problem = toggle.isError ? errorText(toggle.error) : system.data?.problem;

  return (
    <div className={`record${compact ? " record--compact" : ""}`}>
      {capturing && (
        <span className="rec" role="status" aria-label="Recording">
          <span className="rec-dot" aria-hidden="true" />
          <RecMark />
        </span>
      )}
      <button
        type="button"
        className={`btn btn--small record-btn${button.action === "stop" ? " record-btn--stop" : ""}`}
        disabled={!button.enabled || toggle.isPending}
        onClick={() => {
          toggle.reset();
          toggle.mutate(button.action);
        }}
      >
        <span className={button.action === "stop" ? "record-icon record-icon--stop" : "record-icon"} aria-hidden="true" />
        {label}
      </button>
      {!button.enabled && button.reason && <span className="record-note">{button.reason}</span>}
      {problem && (
        <span className="record-note record-note--warn" role="alert">
          {problem}
        </span>
      )}
    </div>
  );
}
