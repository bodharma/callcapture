import { memo, useCallback, useEffect, useMemo, useRef, useState, type MouseEvent } from "react";
import type { SpeakerDTO, TranscriptLine } from "../../api/types";
import { timecode } from "../../lib/format";
import { usePlaybackTime, usePlayer } from "./player";
import { RenameSpeaker } from "./RenameSpeaker";
import "./Transcript.css";

interface TranscriptProps {
  sessionId: string;
  lines: TranscriptLine[];
  /** Seconds to open at (from a search hit): that line is scrolled into view. */
  focusTime?: number;
}

/** Index of the line playing at `time`: the last one that started at or before it. */
function lineAt(lines: TranscriptLine[], time: number): number {
  let found = -1;
  for (let i = 0; i < lines.length && lines[i].start <= time; i += 1) found = i;
  return found;
}

const prefersReducedMotion = () =>
  typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** The full transcript: click a line (or its time) to play from there; click a name to rename. */
export function Transcript({ sessionId, lines, focusTime }: TranscriptProps) {
  const time = usePlaybackTime();
  const player = usePlayer();
  const list = useRef<HTMLOListElement>(null);
  const [renaming, setRenaming] = useState<string | null>(null);
  const active = useMemo(() => lineAt(lines, time), [lines, time]);
  const renameAt = useMemo(() => (renaming === null ? -1 : firstNameAt(lines, renaming)), [lines, renaming]);

  useEffect(() => {
    if (focusTime === undefined) return;
    const index = lineAt(lines, focusTime);
    const row = list.current?.children[index] as HTMLElement | undefined;
    row?.scrollIntoView?.({ block: "center", behavior: prefersReducedMotion() ? "auto" : "smooth" });
  }, [focusTime, lines]);

  const playFrom = useCallback((start: number) => player.seek(start, { play: true }), [player]);

  return (
    <ol className="transcript" ref={list}>
      {lines.map((line, index) => (
        <Line
          key={`${line.start}-${index}`}
          line={line}
          showSpeaker={index === 0 || lines[index - 1].speaker !== line.speaker}
          active={index === active}
          renaming={index === renameAt}
          sessionId={sessionId}
          onPlay={playFrom}
          onRename={setRenaming}
        />
      ))}
    </ol>
  );
}

/** The rename form opens once, under the first shown name of that speaker. */
function firstNameAt(lines: TranscriptLine[], label: string): number {
  return lines.findIndex((line, i) => line.speaker === label && (i === 0 || lines[i - 1].speaker !== label));
}

interface LineProps {
  line: TranscriptLine;
  showSpeaker: boolean;
  active: boolean;
  renaming: boolean;
  sessionId: string;
  onPlay: (start: number) => void;
  onRename: (label: string | null) => void;
}

const Line = memo(function Line({
  line,
  showSpeaker,
  active,
  renaming,
  sessionId,
  onPlay,
  onRename,
}: LineProps) {
  const name = line.name ?? line.speaker;
  const speaker: SpeakerDTO | null = line.speaker
    ? { label: line.speaker, name: name ?? line.speaker, renamed: name !== line.speaker }
    : null;

  // Clicking the text plays from the line, unless the user is selecting text.
  const onRowClick = (event: MouseEvent<HTMLLIElement>) => {
    if ((event.target as HTMLElement).closest("button, input, form, a")) return;
    if (window.getSelection()?.toString()) return;
    onPlay(line.start);
  };

  return (
    <li className={active ? "line line--active" : "line"} aria-current={active || undefined} onClick={onRowClick}>
      <button
        type="button"
        className="line-time"
        aria-label={`Play from ${timecode(line.start)}`}
        onClick={() => onPlay(line.start)}
      >
        {timecode(line.start)}
      </button>
      <div className="line-body">
        {showSpeaker && speaker && (
          <button
            type="button"
            className="line-speaker"
            aria-label={speaker.renamed ? `Rename ${speaker.name} (${speaker.label})` : `Rename ${speaker.label}`}
            title={`Rename ${speaker.label}`}
            onClick={() => onRename(speaker.label)}
          >
            {speaker.name}
          </button>
        )}
        {renaming && speaker && (
          <RenameSpeaker sessionId={sessionId} speaker={speaker} onDone={() => onRename(null)} />
        )}
        <p className="line-text">{line.text}</p>
      </div>
    </li>
  );
});
