import { useId, type ReactNode } from "react";
import { useDownloadModels } from "./api";
import { FieldError, OfflineReason, SettingRow } from "./controls";
import type { ModelState } from "./types";

interface DownloadProps {
  label: string;
  kind: "diarization" | "emotion";
  action: string;
  state: ModelState;
  online: boolean | undefined;
  offlineReason: string;
  hint: ReactNode;
}

/** Model status and a download button that the app runs in the background. */
export function ModelDownloadRow({ label, kind, action, state, online, offlineReason, hint }: DownloadProps) {
  const id = useId();
  const download = useDownloadModels(kind);
  const offline = online === false;
  const status = state.downloading ? "Downloading…" : state.ready ? "Ready" : "Not downloaded";
  return (
    <SettingRow label={label} hint={hint} hintId={`${id}-hint`}>
      <div className="field-line">
        <span className={state.ready ? "model-status model-status--ready" : "model-status"} role="status">
          {status}
        </span>
        <button
          type="button"
          className="btn btn--small"
          disabled={state.ready || state.downloading || download.isPending || offline}
          aria-describedby={`${id}-hint`}
          onClick={() => download.mutate()}
        >
          {action}
        </button>
      </div>
      {offline && !state.ready && <OfflineReason reason={offlineReason} />}
      {state.error && !state.downloading && (
        <p className="field-error" role="alert">
          The download failed. {state.error}
        </p>
      )}
      <FieldError id={`${id}-error`} error={download.error} />
    </SettingRow>
  );
}
