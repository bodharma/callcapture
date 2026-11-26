import { useState } from "react";
import type { SpeakerDTO, SpeakerStats } from "../../api/types";
import { RenameSpeaker } from "./RenameSpeaker";
import "./Transcript.css";

interface SpeakersProps {
  sessionId: string;
  speakers: SpeakerDTO[];
  stats: SpeakerStats[];
}

function statsSentence(stat: SpeakerStats | undefined): string | null {
  if (!stat) return null;
  const share = Math.round(stat.talkRatio * 100);
  const parts = [
    `${share}% of the talking`,
    `${stat.words.toLocaleString("en-GB")} words`,
    `${stat.turns} turns`,
    `${Math.round(stat.wordsPerMin)} words a minute`,
  ];
  if (stat.dominantEmotion) parts.push(`mostly ${stat.dominantEmotion}`);
  return `${parts.join(", ")}.`;
}

/** Everyone the worker heard, with talk stats and a rename form. */
export function Speakers({ sessionId, speakers, stats }: SpeakersProps) {
  const [renaming, setRenaming] = useState<string | null>(null);

  if (speakers.length === 0) {
    return <p className="empty">No speakers yet. They show up here after transcription.</p>;
  }

  return (
    <ul className="speakers">
      {speakers.map((speaker) => {
        const stat = stats.find((s) => s.label === speaker.label);
        const sentence = statsSentence(stat);
        return (
          <li key={speaker.label} className="speaker">
            <div className="speaker-head">
              <span className="speaker-name">{speaker.name}</span>
              {stat?.isSelf
                ? speaker.name.trim().toLowerCase() !== "you" && <span className="speaker-label">you</span>
                : speaker.renamed && <span className="speaker-label">{speaker.label}</span>}
              {renaming !== speaker.label && (
                <button
                  type="button"
                  className="btn btn--small btn--quiet"
                  aria-label={`Rename ${speaker.name}`}
                  onClick={() => setRenaming(speaker.label)}
                >
                  Rename
                </button>
              )}
            </div>
            {sentence && <p className="speaker-stats">{sentence}</p>}
            {renaming === speaker.label && (
              <RenameSpeaker sessionId={sessionId} speaker={speaker} onDone={() => setRenaming(null)} />
            )}
          </li>
        );
      })}
    </ul>
  );
}
