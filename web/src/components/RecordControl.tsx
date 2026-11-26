import { useMutation } from "@tanstack/react-query";
import { apiSend, errorText } from "../api/client";
import type { RecordingState } from "../api/events";
import { useSystem } from "../features/sessions/api";
import "./topbar.css";

/** The phase from the app; older answers only carry the `recording` flag. */
function phaseOf(data: { recording: boolean; recordingState?: RecordingState } | undefined): RecordingState | undefined {
  if (!data) return undefined;
  return data.recordingState ?? (data.recording ? "recording" : "idle");
}

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
 * Record / Stop for the web UI, driven by the app's recording state (events keep it
 * current). Permission prompts appear natively; a refused or failed start is shown
 * as a sentence next to the button.
 */
export function RecordControl({ compact = false }: RecordControlProps) {
  const system = useSystem();
  const phase = phaseOf(system.data);
  const toggle = useMutation({
    mutationFn: (action: "start" | "stop") => apiSend<{ started: boolean }>("POST", `/api/recording/${action}`),
  });
  // Nothing to offer until the app has said what it is doing.
  if (phase === undefined) return null;
  const recordingNow = phase === "recording" || phase === "stopping" || phase === "starting";
  const label =
    phase === "starting" ? "Starting…" : phase === "stopping" ? "Stopping…" : phase === "recording" ? "Stop" : "Record";
  const busy = toggle.isPending || phase === "starting" || phase === "stopping";
  const disabled = phase === "processing" || busy;
  const reason = phase === "processing" ? "Processing a session." : undefined;
  const problem = toggle.isError ? errorText(toggle.error) : system.data?.problem;

  return (
    <div className={`record${compact ? " record--compact" : ""}`}>
      {recordingNow && (
        <span className="rec" role="status" aria-label="Recording">
          <span className="rec-dot" aria-hidden="true" />
          <RecMark />
        </span>
      )}
      <button
        type="button"
        className={`btn btn--small record-btn${phase === "recording" ? " record-btn--stop" : ""}`}
        disabled={disabled}
        onClick={() => {
          toggle.reset();
          toggle.mutate(phase === "recording" ? "stop" : "start");
        }}
      >
        <span className={phase === "recording" ? "record-icon record-icon--stop" : "record-icon"} aria-hidden="true" />
        {label}
      </button>
      {reason && <span className="record-note">{reason}</span>}
      {problem && (
        <span className="record-note record-note--warn" role="alert">
          {problem}
        </span>
      )}
    </div>
  );
}
