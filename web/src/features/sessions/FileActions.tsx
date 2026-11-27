import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useId, useRef, useState } from "react";
import { useNavigate } from "react-router";
import { errorText } from "../../api/client";
import type { SessionDTO } from "../../api/types";
import { forgetSession, useDeleteSession, useReveal } from "./api";

/**
 * The audio file, Show in Finder, and Delete with an in-page confirmation. Whether
 * Delete can run comes from the app (`canDelete`, `deleteBlocked`), which knows what it
 * is recording or processing; the stored status alone can be stale after a quit.
 */
export function FileActions({ session }: { session: SessionDTO }) {
  const reveal = useReveal(session.id);
  const remove = useDeleteSession(session.id);
  const client = useQueryClient();
  const navigate = useNavigate();
  const [confirming, setConfirming] = useState(false);
  const cancelButton = useRef<HTMLButtonElement>(null);
  const deleteButton = useRef<HTMLButtonElement>(null);
  const reasonId = useId();
  const blocked = session.canDelete === false;
  const reason = blocked ? session.deleteBlocked : undefined;

  useEffect(() => {
    if (confirming) cancelButton.current?.focus();
  }, [confirming]);

  const cancel = () => {
    setConfirming(false);
    deleteButton.current?.focus();
  };

  const confirmDelete = () =>
    remove.mutate(undefined, {
      onSuccess: () => {
        navigate("/sessions");
        forgetSession(client, session.id);
      },
    });

  return (
    <section className="files" aria-label="Files">
      <div className="files-row">
        <span className="files-name">{session.audioFileName}</span>
        <button type="button" className="btn btn--small btn--quiet" onClick={() => reveal.mutate()}>
          Show in Finder
        </button>
        <button
          ref={deleteButton}
          type="button"
          className="btn btn--small btn--danger"
          disabled={blocked}
          aria-expanded={confirming}
          aria-describedby={reason ? reasonId : undefined}
          onClick={() => setConfirming(true)}
        >
          Delete session
        </button>
      </div>
      {reason && (
        <p id={reasonId} className="files-reason">
          {reason}
        </p>
      )}
      {confirming && !blocked && (
        <div
          className="confirm"
          role="group"
          aria-label="Confirm delete"
          onKeyDown={(event) => {
            if (event.key === "Escape") cancel();
          }}
        >
          <p>
            Delete “{session.title}”? This permanently removes the audio, transcript, note and analysis
            files.
          </p>
          <div className="confirm-row">
            <button
              type="button"
              className="btn btn--danger-solid"
              disabled={remove.isPending}
              onClick={confirmDelete}
            >
              Delete session and files
            </button>
            <button ref={cancelButton} type="button" className="btn btn--quiet" onClick={cancel}>
              Cancel
            </button>
          </div>
        </div>
      )}
      {reveal.isError && (
        <p className="notice notice--warn" role="alert">
          Showing the file in Finder failed. {errorText(reveal.error)}
        </p>
      )}
      {remove.isError && (
        <p className="notice notice--warn" role="alert">
          Deleting failed. {errorText(remove.error)}
        </p>
      )}
    </section>
  );
}
