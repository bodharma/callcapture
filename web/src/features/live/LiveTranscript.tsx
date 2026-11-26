import type { LiveSnapshot, LiveSource, LiveTurn } from "../../api/liveTypes";
import { timecode } from "../../lib/format";
import { speaker } from "./liveFormat";

export function TurnLine({ turn }: { turn: LiveTurn }) {
  return (
    <li className="turn">
      <span className="turn-meta">
        {timecode(turn.start)} · {speaker(turn.source)}
      </span>
      <p className="turn-text">{turn.text}</p>
    </li>
  );
}

const SOURCES: readonly LiveSource[] = ["mic", "system"];

/** Committed live turns in time order, then any partial speech still being heard. */
export function LiveTranscript({ view }: { view: LiveSnapshot }) {
  const partials = SOURCES.flatMap((source) => {
    const text = view.partials[source];
    return text ? [{ source, text }] : [];
  });
  if (view.turns.length === 0 && partials.length === 0) {
    return <p className="empty">Committed local speech shows up here.</p>;
  }
  return (
    <div className="live-transcript">
      <ol className="turns">
        {view.turns.map((turn) => (
          <TurnLine key={turn.id} turn={turn} />
        ))}
      </ol>
      {partials.map(({ source, text }) => (
        <p key={source} className="turn-partial">
          {speaker(source)} · partial: {text}
        </p>
      ))}
    </div>
  );
}
