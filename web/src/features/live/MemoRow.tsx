import { useState } from "react";
import { errorText } from "../../api/client";
import type { LiveMemo } from "../../api/liveTypes";
import { seg, useLiveAction, type LiveTarget } from "./api";
import { memoLabel } from "./liveFormat";

const MAX_MEMO = 2_000;

interface MemoRowProps {
  memo: LiveMemo;
  topicID: string;
  target: LiveTarget;
}

/** One memo: read, edit (an edit makes it yours), pin. */
export function MemoRow({ memo, topicID, target }: MemoRowProps) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const edit = useLiveAction(target);
  const pin = useLiveAction(target);
  const base = `memos/${seg(topicID)}/${seg(memo.id)}`;
  const error = edit.error ?? pin.error;

  return (
    <article className={`memo memo--${memo.kind}${memo.pinned ? " memo--pinned" : ""}`}>
      <span className="memo-label">{memoLabel(memo)}</span>
      {editing ? (
        <>
          <label className="visually-hidden" htmlFor={`memo-${memo.id}`}>
            Memo
          </label>
          <textarea
            id={`memo-${memo.id}`}
            className="field memo-edit"
            rows={3}
            value={draft}
            maxLength={MAX_MEMO}
            onChange={(event) => setDraft(event.target.value)}
          />
        </>
      ) : (
        <p className="memo-text">{memo.text}</p>
      )}
      <div className="memo-actions">
        {editing ? (
          <>
            <button
              type="button"
              className="btn btn--small"
              disabled={draft.trim() === "" || edit.isPending}
              onClick={() =>
                edit.mutate({ path: `${base}/edit`, body: { text: draft } }, { onSuccess: () => setEditing(false) })
              }
            >
              Save edit
            </button>
            <button type="button" className="btn btn--small btn--quiet" onClick={() => setEditing(false)}>
              Cancel
            </button>
          </>
        ) : (
          <button
            type="button"
            className="btn btn--small btn--quiet"
            onClick={() => {
              edit.reset();
              setDraft(memo.text);
              setEditing(true);
            }}
          >
            Edit
          </button>
        )}
        <button
          type="button"
          className="btn btn--small btn--quiet"
          disabled={pin.isPending}
          onClick={() => pin.mutate({ path: `${base}/pin`, body: { pinned: !memo.pinned } })}
        >
          {memo.pinned ? "Unpin note" : "Pin note"}
        </button>
      </div>
      {error && (
        <p className="live-error" role="alert">
          {errorText(error)}
        </p>
      )}
    </article>
  );
}
