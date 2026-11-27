import { useEffect, useId, useRef, useState } from "react";
import { errorText } from "../../api/client";
import type { SessionDTO } from "../../api/types";
import { sessionPath, useRegenerateNotes, useReprocess, useSaveToVault } from "./api";

/** The run button follows the status, as in the app: Transcribe, Re-process or Retry. */
export function reprocessLabel(status: string): string | null {
  if (status === "completed") return "Transcribe";
  if (status === "transcribed") return "Re-process";
  if (status === "error" || status === "failed" || status === "interrupted") return "Retry";
  return null;
}

/**
 * Re-process, Regenerate AI notes, Export and Save to vault, with their results shown
 * inline underneath.
 */
export function SessionActions({ session }: { session: SessionDTO }) {
  const reprocess = useReprocess(session.id);
  const regenerate = useRegenerateNotes(session.id);
  const vault = useSaveToVault(session.id);
  const label = reprocessLabel(session.status);
  const reasonId = useId();
  const regenerateReasonId = useId();
  // The app's own sentences, shown before any click while an action can't run.
  const blocked = label ? session.reprocessBlocked : undefined;
  // Regenerating needs only the saved transcript: nothing is transcribed again.
  const canRegenerate = session.hasTranscript;
  const regenerateBlocked = canRegenerate ? session.regenerateBlocked : undefined;
  // One sentence when both are off for the same reason (a recording, another run).
  const sharedReason = blocked !== undefined && blocked === regenerateBlocked;
  const resetResults = () => [reprocess, regenerate, vault].forEach((action) => action.reset());

  return (
    <div className="actions">
      <div className="actions-row">
        {label && (
          <button
            type="button"
            className="btn"
            disabled={reprocess.isPending || blocked !== undefined}
            aria-describedby={blocked ? reasonId : undefined}
            onClick={() => {
              resetResults();
              reprocess.mutate();
            }}
          >
            {label}
          </button>
        )}
        {canRegenerate && (
          <button
            type="button"
            className="btn"
            disabled={regenerate.isPending || regenerateBlocked !== undefined}
            aria-describedby={regenerateBlocked ? (sharedReason ? reasonId : regenerateReasonId) : undefined}
            onClick={() => {
              resetResults();
              regenerate.mutate();
            }}
          >
            Regenerate AI notes
          </button>
        )}
        <ExportMenu session={session} />
        <button
          type="button"
          className="btn btn--primary"
          disabled={!session.hasNote || vault.isPending}
          title={session.hasNote ? undefined : "There is no note to save yet."}
          onClick={() => {
            resetResults();
            vault.mutate();
          }}
        >
          Save to vault
        </button>
      </div>
      {blocked && (
        <p id={reasonId} className="actions-reason">
          {blocked}
        </p>
      )}
      {regenerateBlocked && !sharedReason && (
        <p id={regenerateReasonId} className="actions-reason">
          {regenerateBlocked}
        </p>
      )}
      {reprocess.isError && (
        <p className="notice notice--warn" role="alert">
          {label ?? "Processing"} didn't start. {errorText(reprocess.error)}
        </p>
      )}
      {regenerate.isError && (
        <p className="notice notice--warn" role="alert">
          Regenerating AI notes didn't start. {errorText(regenerate.error)}
        </p>
      )}
      {vault.isError && (
        <p className="notice notice--warn" role="alert">
          Saving to the vault failed. {errorText(vault.error)}
        </p>
      )}
      {vault.isSuccess && (
        <p className="notice notice--ok" role="status">
          Saved to <span className="mono">{vault.data.path}</span>
        </p>
      )}
    </div>
  );
}

const FORMATS = [
  { format: "md", label: "Markdown", needs: "hasNote" },
  { format: "txt", label: "Plain text", needs: "hasNote" },
  { format: "json", label: "JSON", needs: "hasTranscript" },
] as const;

/**
 * Plain same-origin links: the server answers with an attachment, which the
 * browser downloads and the app window saves through a save panel.
 */
function ExportMenu({ session }: { session: SessionDTO }) {
  const [open, setOpen] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const menuId = useId();
  const available = FORMATS.filter((entry) => session[entry.needs]);

  useEffect(() => {
    if (!open) return;
    const onPointer = (event: PointerEvent) => {
      if (!wrap.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("pointerdown", onPointer);
    return () => document.removeEventListener("pointerdown", onPointer);
  }, [open]);

  return (
    <div
      className="export"
      ref={wrap}
      onKeyDown={(event) => {
        if (event.key === "Escape") setOpen(false);
      }}
    >
      <button
        type="button"
        className="btn"
        aria-expanded={open}
        aria-controls={menuId}
        disabled={available.length === 0}
        title={available.length === 0 ? "Nothing to export yet. Transcribe the session first." : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        Export
      </button>
      {open && (
        <ul className="export-menu" id={menuId}>
          {available.map((entry) => (
            <li key={entry.format}>
              <a href={`${sessionPath(session.id)}/export?format=${entry.format}`} onClick={() => setOpen(false)}>
                {entry.label}
              </a>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
