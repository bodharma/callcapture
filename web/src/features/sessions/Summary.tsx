import { lazy, Suspense, useId, type ReactNode } from "react";
import { Link } from "react-router";
import type { AnalysisDTO, MarkerKind, SpeakerDTO, SpeakerStats, TapeMarker } from "../../api/types";
import { timecode } from "../../lib/format";
import { usePlayer } from "./player";
import "./Summary.css";

// The Markdown renderer is the largest dependency; load it only when a note is shown.
const Note = lazy(() => import("./Note").then((module) => ({ default: module.Note })));

interface SummaryProps {
  status: string;
  analysis: AnalysisDTO | null | undefined;
  note: string | null | undefined;
  markers: TapeMarker[];
  speakers: SpeakerDTO[];
}

/**
 * The worker's untimed insights plus the vault note. Decisions, questions and
 * your notes are timed only where the live map recorded them (tape markers).
 */
export function Summary({ status, analysis, note, markers, speakers }: SummaryProps) {
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
        <TimedList title="Open questions" kind="question" markers={timed("question")} />
        <TimedList title="Your notes" kind="note" markers={timed("note")} />
        <PlainList title="Key points" items={insights?.keyPoints} />
        <PlainList title="Takeaways" items={insights?.takeaways} />
        {note && (
          <Block title="Note">
            <Suspense fallback={<p className="empty">Loading the note…</p>}>
              <Note markdown={note} />
            </Suspense>
          </Block>
        )}
      </div>
      {analysis && analysis.speakers.length > 0 && (
        <WhoSpoke stats={analysis.speakers} speakers={speakers} />
      )}
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

const SEGMENTS = 25;

const isYou = (name: string): boolean => name.trim().toLowerCase() === "you";

function WhoSpoke({ stats, speakers }: { stats: SpeakerStats[]; speakers: SpeakerDTO[] }) {
  const id = useId();
  const sorted = [...stats].sort((a, b) => b.talkRatio - a.talkRatio);
  const unnamed = speakers.find((speaker) => !speaker.renamed);
  return (
    <aside className="who" aria-labelledby={id}>
      <h2 id={id} className="block-title">
        Who spoke
      </h2>
      {sorted.map((speaker) => {
        const share = Math.round(Math.min(1, Math.max(0, speaker.talkRatio)) * 100);
        const lit = Math.round((share / 100) * SEGMENTS);
        return (
          <div key={speaker.label} className="who-row">
            <span className="who-head">
              <span>{speaker.isSelf && !isYou(speaker.name) ? `${speaker.name} (you)` : speaker.name}</span>
              <span className="who-share">{share}%</span>
            </span>
            <span className="meter" role="img" aria-label={`${speaker.name} spoke ${share}% of the time`}>
              {Array.from({ length: SEGMENTS }, (_, i) => (
                <span key={i} className={i < lit ? "meter-seg meter-seg--on" : "meter-seg"} />
              ))}
            </span>
          </div>
        );
      })}
      {unnamed && (
        <Link className="who-name" to="?tab=speakers">
          Name {unnamed.label}
        </Link>
      )}
    </aside>
  );
}
