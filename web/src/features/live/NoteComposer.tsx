import { useState, type RefObject } from "react";
import { errorText } from "../../api/client";
import { MEMO_KINDS, type MemoKind } from "../../api/liveTypes";
import { useLiveAction, type LiveTarget } from "./api";

const MAX_NOTE = 2_000;

interface NoteComposerProps {
  target: LiveTarget;
  /** Saved maps keep the selection in the page, so the note says where it goes. */
  topicID?: string;
  compact?: boolean;
  inputRef?: RefObject<HTMLTextAreaElement | HTMLInputElement | null>;
}

const capitalized = (kind: MemoKind): string => kind[0].toUpperCase() + kind.slice(1);

/** "Your thought or question": a manual note on the selected (or current) topic. */
export function NoteComposer({ target, topicID, compact = false, inputRef }: NoteComposerProps) {
  const [text, setText] = useState("");
  const [kind, setKind] = useState<MemoKind>("note");
  const add = useLiveAction(target);
  const blank = text.trim() === "";

  const submit = () => {
    if (blank || add.isPending) return;
    add.mutate(
      { path: "note", body: { text, kind, ...(topicID ? { topicID } : {}) } },
      { onSuccess: () => setText("") },
    );
  };

  return (
    <form
      className={compact ? "composer composer--compact" : "composer"}
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      {compact ? (
        <>
          <span className="composer-prompt" aria-hidden="true">
            &gt;
          </span>
          <label className="visually-hidden" htmlFor="live-note">
            Add a thought
          </label>
          <input
            id="live-note"
            ref={inputRef as RefObject<HTMLInputElement>}
            className="composer-input"
            value={text}
            maxLength={MAX_NOTE}
            placeholder="add a thought without losing your place"
            autoComplete="off"
            onChange={(event) => setText(event.target.value)}
          />
        </>
      ) : (
        <>
          <label className="composer-kind">
            <span className="visually-hidden">Kind</span>
            <select className="field" value={kind} onChange={(event) => setKind(event.target.value as MemoKind)}>
              {MEMO_KINDS.map((option) => (
                <option key={option} value={option}>
                  {capitalized(option)}
                </option>
              ))}
            </select>
          </label>
          <label className="visually-hidden" htmlFor="live-note">
            Your thought or question
          </label>
          <textarea
            id="live-note"
            ref={inputRef as RefObject<HTMLTextAreaElement>}
            className="field composer-text"
            rows={2}
            value={text}
            maxLength={MAX_NOTE}
            placeholder="Write a personal note"
            onChange={(event) => setText(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) submit();
            }}
          />
        </>
      )}
      <button type="submit" className="btn btn--small composer-add" disabled={blank || add.isPending}>
        Add
      </button>
      {add.isError && (
        <p className="live-error" role="alert">
          {errorText(add.error)}
        </p>
      )}
    </form>
  );
}
