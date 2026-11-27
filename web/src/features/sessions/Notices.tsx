import type { SessionDTO } from "../../api/types";
import { reprocessLabel } from "./SessionActions";

const sentence = (text: string): string => (/[.!?]$/.test(text.trim()) ? text.trim() : `${text.trim()}.`);

/** Processing progress, the last run's failure, and the worker's warnings. */
export function Notices({ session, analysisWarnings }: { session: SessionDTO; analysisWarnings: string[] }) {
  const warnings = [...new Set([session.warning, ...analysisWarnings].filter((w): w is string => !!w))];
  const retry = reprocessLabel(session.status);
  // A run cut short with the transcript saved (the app settles it as "transcribed"):
  // the cheap way back is new notes from that transcript, not another transcription.
  const advice =
    session.status === "transcribed" && session.hasTranscript
      ? " Use Regenerate AI notes to remake the notes from the saved transcript."
      : retry
        ? ` Use ${retry} to run it again.`
        : "";

  return (
    <>
      {session.status === "transcribing" && (
        <p className="notice notice--live" role="status">
          {session.stage ?? "Processing this session"}. This page updates when it's done.
        </p>
      )}
      {session.error && session.status !== "transcribing" && (
        <p className="notice notice--warn" role="alert">
          The last processing run didn't finish. {sentence(session.error)}
          {advice}
        </p>
      )}
      {warnings.length > 0 && (
        <section className="warnings" aria-label="Warnings">
          <ul>
            {warnings.map((warning) => (
              <li key={warning}>{warning}</li>
            ))}
          </ul>
        </section>
      )}
    </>
  );
}
