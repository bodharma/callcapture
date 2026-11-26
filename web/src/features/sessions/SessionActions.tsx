import { useEffect, useId, useRef, useState } from "react";
import { errorText } from "../../api/client";
import type { SessionDTO } from "../../api/types";
import { sessionPath, useReprocess, useSaveToVault } from "./api";

/** The run button follows the status, as in the app: Transcribe, Re-process or Retry. */
export function reprocessLabel(status: string): string | null {
  if (status === "completed") return "Transcribe";
  if (status === "transcribed") return "Re-process";
  if (status === "error" || status === "failed" || status === "interrupted") return "Retry";
  return null;
}

/** Re-process, Export and Save to vault, with their results shown inline underneath. */
export function SessionActions({ session }: { session: SessionDTO }) {
  const reprocess = useReprocess(session.id);
  const vault = useSaveToVault(session.id);
  const label = reprocessLabel(session.status);

  return (
    <div className="actions">
      <div className="actions-row">
        {label && (
          <button
            type="button"
            className="btn"
            disabled={reprocess.isPending}
            onClick={() => {
              vault.reset();
              reprocess.mutate();
            }}
          >
            {label}
          </button>
        )}
        <ExportMenu session={session} />
        <button
          type="button"
          className="btn btn--primary"
          disabled={!session.hasNote || vault.isPending}
          title={session.hasNote ? undefined : "There is no note to save yet."}
          onClick={() => {
            reprocess.reset();
            vault.mutate();
          }}
        >
          Save to vault
        </button>
      </div>
      {reprocess.isError && (
        <p className="notice notice--warn" role="alert">
          {label ?? "Processing"} didn't start. {errorText(reprocess.error)}
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
