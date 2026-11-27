import { lazy, Suspense, useId, useState, type ReactNode } from "react";
import type { AnalysisDTO, MarkerKind, SpeakerDTO, TapeMarker } from "../../api/types";
import { timecode } from "../../lib/format";
import { errorText } from "../../api/client";
import { useOpenNote } from "./api";
import { usePlayer } from "./player";
import { SummarySide } from "./SummarySide";
import "./Summary.css";

// The Markdown renderer is the largest dependency; load it only when the note is opened.
const Note = lazy(() => import("./Note").then((module) => ({ default: module.Note })));

interface SummaryProps {
  status: string;
  analysis: AnalysisDTO | null | undefined;
  note: string | null | undefined;
  markers: TapeMarker[];
  speakers: SpeakerDTO[];
  /** The session whose Markdown note file can be opened in the default app; absent without a file. */
  noteSessionId?: string;
}

/**
 * The structured lists first (summary, decisions, action items, recommended
 * actions, open questions, then your notes, key points and takeaways), and the
 * full vault note below in a disclosure that starts closed. The side column
 * shows the overall tone and who spoke. Decisions, questions and your notes are
 * timed only where the live map recorded them (tape markers).
 */
export function Summary({ status, analysis, note, markers, speakers, noteSessionId }: SummaryProps) {
  const insights = analysis?.insights;
  const timed = (kind: MarkerKind) => markers.filter((marker) => marker.kind === kind);
  const hasAnything = !!insights?.summary || markers.length > 0 || !!note || !!insights;

  if (!hasAnything) return <p className="empty">{emptyText(status)}</p>;

  return (
    <div className="summary">
      <div className="summary-main">
        {insights?.summary && <p className="summary-lead">{insights.summary}</p>}
        <TimedList title="Decided" kind="decision" markers={timed("decision")} />
        <PlainList title="To do" items={insights?.actionItems} />
        <PlainList title="Recommended actions" items={insights?.recommendedActions} />
        <TimedList title="Open questions" kind="question" markers={timed("question")} />
        <TimedList title="Your notes" kind="note" markers={timed("note")} />
        <PlainList title="Key points" items={insights?.keyPoints} />
        <PlainList title="Takeaways" items={insights?.takeaways} />
        {note && <FullNote markdown={note} sessionId={noteSessionId} />}
      </div>
      {analysis && <SummarySide analysis={analysis} speakers={speakers} />}
    </div>
  );
}

function emptyText(status: string): string {
  if (status === "transcribing") return "Processing this session. The summary shows up here when it's done.";
  if (status === "completed") return "No summary yet. Transcribe the session to get one.";
  if (status === "recording") return "Still recording. The summary comes after you stop and transcribe.";
  return "This session has no summary.";
}

function Block({ title, children }: { title: string; children: ReactNode }) {
  const id = useId();
  return (
    <section className="block" aria-labelledby={id}>
      <h2 id={id} className="block-title">
        {title}
      </h2>
      {children}
    </section>
  );
}

/** The vault note, which repeats much of the lists above: closed until asked for. */
function FullNote({ markdown, sessionId }: { markdown: string; sessionId?: string }) {
  const [open, setOpen] = useState(false);
  const panelId = useId();
  return (
    <section className="block">
      <div className="block-head">
        <h2 className="block-title">
          <button
            type="button"
            className="disclosure"
            aria-expanded={open}
            aria-controls={panelId}
            onClick={() => setOpen((value) => !value)}
          >
            Full note
          </button>
        </h2>
        {sessionId !== undefined && <OpenNote sessionId={sessionId} />}
      </div>
      <div id={panelId} hidden={!open}>
        {open && (
          <Suspense fallback={<p className="empty">Loading the note…</p>}>
            <Note markdown={markdown} />
          </Suspense>
        )}
      </div>
    </section>
  );
}

/** Opens the note's Markdown file in the app that handles it; a failure is said inline. */
function OpenNote({ sessionId }: { sessionId: string }) {
  const open = useOpenNote(sessionId);
  return (
    <span className="open-note">
      <button type="button" className="btn btn--small" disabled={open.isPending} onClick={() => open.mutate()}>
        Open note
      </button>
      {open.isError && (
        <span className="field-note" role="alert">
          Couldn't open the note. {errorText(open.error)}
        </span>
      )}
    </span>
  );
}

function TimedList({ title, kind, markers }: { title: string; kind: MarkerKind; markers: TapeMarker[] }) {
  const player = usePlayer();
  if (markers.length === 0) return null;
  return (
    <Block title={title}>
      <ul className="timed">
        {markers.map((marker) => (
          <li key={marker.id}>
            <button
              type="button"
              className={`timed-at timed-at--${kind}`}
              aria-label={`Play from ${timecode(marker.time)}`}
              onClick={() => player.seek(marker.time, { play: true })}
            >
              {timecode(marker.time)}
            </button>
            <span>{marker.text}</span>
          </li>
        ))}
      </ul>
    </Block>
  );
}

function PlainList({ title, items }: { title: string; items: string[] | undefined }) {
  if (!items || items.length === 0) return null;
  return (
    <Block title={title}>
      <ul className="plain">
        {items.map((item, index) => (
          <li key={`${index}-${item}`}>{item}</li>
        ))}
      </ul>
    </Block>
  );
}
