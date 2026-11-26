import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router";
import { errorText } from "../../api/client";
import type { SessionDTO } from "../../api/types";
import { forgetSession, useDeleteSession, useReveal } from "./api";

/** The audio file, Show in Finder, and Delete with an in-page confirmation. */
export function FileActions({ session }: { session: SessionDTO }) {
  const reveal = useReveal(session.id);
  const remove = useDeleteSession(session.id);
  const client = useQueryClient();
  const navigate = useNavigate();
  const [confirming, setConfirming] = useState(false);
  const cancelButton = useRef<HTMLButtonElement>(null);
  const deleteButton = useRef<HTMLButtonElement>(null);
  const busy = session.status === "recording" || session.status === "transcribing";

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
          disabled={busy}
          aria-expanded={confirming}
          title={busy ? "A session can't be deleted while it records or is processed." : undefined}
          onClick={() => setConfirming(true)}
        >
          Delete session
        </button>
      </div>
      {confirming && (
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
