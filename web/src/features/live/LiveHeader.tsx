import { useState } from "react";
import { errorText } from "../../api/client";
import type { LiveSnapshot } from "../../api/liveTypes";
import { languageName, timecode } from "../../lib/format";
import { useLiveAction, type LiveTarget } from "./api";
import { currentTopicTitle, usageLine } from "./liveFormat";

interface LiveHeaderProps {
  view: LiveSnapshot;
  target: LiveTarget;
  onAddThought: () => void;
}

function NotesLanguagePicker({ view, target }: { view: LiveSnapshot; target: LiveTarget }) {
  const choose = useLiveAction(target);
  return (
    <div className="live-language">
      <label className="visually-hidden" htmlFor="notes-language">
        Choose notes language
      </label>
      <select
        id="notes-language"
        className="field"
        value=""
        disabled={choose.isPending}
        onChange={(event) => choose.mutate({ path: "notes-language", body: { code: event.target.value } })}
      >
        <option value="" disabled>
          Choose notes language
        </option>
        {view.notesLanguageChoices.map((code) => (
          <option key={code} value={code}>
            {languageName(code)}
          </option>
        ))}
      </select>
      {choose.isError && (
        <p className="live-error" role="alert">
          {errorText(choose.error)}
        </p>
      )}
    </div>
  );
}

/** Title, processing and map status, notes language, spend, and the meeting actions. */
export function LiveHeader({ view, target, onAddThought }: LiveHeaderProps) {
  const catchUp = useLiveAction(target);
  const backToLive = useLiveAction(target);
  const exporter = useLiveAction(target);
  const [exported, setExported] = useState<string>();
  const mapped =
    view.mappedThroughSeconds === undefined
      ? view.status
      : `Topic map through ${timecode(view.mappedThroughSeconds)} · ${view.status}`;
  const actionError = catchUp.error ?? backToLive.error;

  return (
    <header className="live-head">
      <div className="live-head-text">
        <h1 className="live-title">{view.title || "Live meeting"}</h1>
        <p className="live-line">{view.processingStatus}</p>
        <p className="live-current">Current mapped topic: {currentTopicTitle(view)}</p>
        <p className="live-line">{mapped}</p>
        <p className="live-line">
          Notes language:{" "}
          {view.resolvedNotesLanguage ? languageName(view.resolvedNotesLanguage) : "awaiting speech detection"}
        </p>
        {view.usage && <p className="live-line live-spend">{usageLine(view.usage)}</p>}
        {view.canChooseNotesLanguage && <NotesLanguagePicker view={view} target={target} />}
        {!view.microphoneEnabled && <p className="live-line">Microphone off · Remote audio only</p>}
      </div>
      <div className="live-actions">
        <div className="live-buttons">
          {view.active && (
            <button type="button" className="btn btn--small" title="⌘⇧J" onClick={() => catchUp.mutate({ path: "catch-up" })}>
              What did I miss?
            </button>
          )}
          <button type="button" className="btn btn--small" title="⌘⇧N" onClick={onAddThought}>
            Add thought
          </button>
          {view.active && (
            <button
              type="button"
              className="btn btn--small"
              title="⌘⇧L"
              onClick={() => backToLive.mutate({ path: "back-to-live" })}
            >
              Back to live
            </button>
          )}
          <button
            type="button"
            className="btn btn--small"
            disabled={exporter.isPending}
            onClick={() => {
              setExported(undefined);
              exporter.mutate(
                { path: "export" },
                { onSuccess: (answer) => setExported(answer?.path ? `Saved ${answer.path}` : "Export cancelled.") },
              );
            }}
          >
            Export…
          </button>
        </div>
        {!view.active && <p className="live-hint">The meeting has ended, so there is nothing to catch up on.</p>}
        {exporter.isPending && <p className="live-hint">Choose a folder in the window CallCapture opened.</p>}
        {exported && <p className="live-hint live-exported">{exported}</p>}
        {exporter.isError && (
          <p className="live-error" role="alert">
            {errorText(exporter.error)}
          </p>
        )}
        {actionError && (
          <p className="live-error" role="alert">
            {errorText(actionError)}
          </p>
        )}
      </div>
    </header>
  );
}
