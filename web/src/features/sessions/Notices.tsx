import type { SessionDTO } from "../../api/types";
import { reprocessLabel } from "./SessionActions";

const sentence = (text: string): string => (/[.!?]$/.test(text.trim()) ? text.trim() : `${text.trim()}.`);

/** Processing progress, the last run's failure, and the worker's warnings. */
export function Notices({ session, analysisWarnings }: { session: SessionDTO; analysisWarnings: string[] }) {
  const warnings = [...new Set([session.warning, ...analysisWarnings].filter((w): w is string => !!w))];
  const retry = reprocessLabel(session.status);

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
          {retry ? ` Use ${retry} to run it again.` : ""}
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
