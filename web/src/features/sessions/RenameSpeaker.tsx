import { useEffect, useRef, useState, type FormEvent } from "react";
import { errorText } from "../../api/client";
import type { SpeakerDTO } from "../../api/types";
import { useRenameSpeaker } from "./api";

interface RenameSpeakerProps {
  sessionId: string;
  speaker: Pick<SpeakerDTO, "label" | "name" | "renamed">;
  onDone: () => void;
}

/** Inline rename form. An empty name restores the worker's label. */
export function RenameSpeaker({ sessionId, speaker, onDone }: RenameSpeakerProps) {
  const rename = useRenameSpeaker(sessionId);
  const [name, setName] = useState(speaker.renamed ? speaker.name : "");
  const input = useRef<HTMLInputElement>(null);
  const inputId = `rename-${sessionId}-${speaker.label}`.replace(/\s+/g, "-");

  useEffect(() => input.current?.focus(), []);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    rename.mutate({ label: speaker.label, name: name.trim() }, { onSuccess: onDone });
  };

  return (
    <form
      className="rename"
      onSubmit={submit}
      onKeyDown={(event) => {
        if (event.key === "Escape") onDone();
      }}
    >
      <label className="visually-hidden" htmlFor={inputId}>
        Name for {speaker.label}
      </label>
      <input
        id={inputId}
        ref={input}
        className="field"
        value={name}
        placeholder={speaker.label}
        autoComplete="off"
        onChange={(event) => setName(event.target.value)}
      />
      <button type="submit" className="btn btn--small" disabled={rename.isPending}>
        Save name
      </button>
      <button type="button" className="btn btn--small btn--quiet" onClick={onDone}>
        Cancel
      </button>
      <span className="rename-hint">
        Used in the transcript, notes, search and exports. Leave it empty to go back to “
        {speaker.label}”.
      </span>
      {rename.isError && (
        <span className="notice notice--warn" role="alert">
          Renaming failed. {errorText(rename.error)}
        </span>
      )}
    </form>
  );
}
