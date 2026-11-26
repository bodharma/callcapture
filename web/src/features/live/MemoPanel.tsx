import { errorText } from "../../api/client";
import type { LiveSnapshot, LiveTopic } from "../../api/liveTypes";
import { seg, useLiveAction, type LiveTarget } from "./api";
import { TurnLine } from "./LiveTranscript";
import { MemoRow } from "./MemoRow";
import { TopicControls } from "./TopicControls";

interface MemoPanelProps {
  view: LiveSnapshot;
  topic: LiveTopic | undefined;
  target: LiveTarget;
}

/** The selected topic: pin, rename/move/merge, summary, memos and the speech behind it. */
export function MemoPanel({ view, topic, target }: MemoPanelProps) {
  const pin = useLiveAction(target);
  if (!topic) {
    return (
      <section className="memo-panel" aria-label="Selected topic">
        <h2 className="memo-panel-title">Waiting for a topic</h2>
        <p className="empty">Committed local speech and your notes appear here.</p>
      </section>
    );
  }
  const evidence = new Set(topic.turnIDs);
  const turns = view.turns.filter((turn) => evidence.has(turn.id));

  return (
    <section className="memo-panel" aria-label={`Notes on ${topic.title}`}>
      <div className="memo-panel-head">
        <h2 className="memo-panel-title">{topic.title}</h2>
        <button
          type="button"
          className="btn btn--small"
          disabled={pin.isPending}
          onClick={() => pin.mutate({ path: `topics/${seg(topic.id)}/pin`, body: { pinned: !topic.pinned } })}
        >
          {topic.pinned ? "Unpin topic" : "Pin topic"}
        </button>
      </div>
      {pin.isError && (
        <p className="live-error" role="alert">
          {errorText(pin.error)}
        </p>
      )}
      <TopicControls key={topic.id} topic={topic} topics={view.topics} target={target} />
      {topic.summary && <p className="memo-summary">{topic.summary}</p>}
      <div className="memos">
        {topic.memos.map((memo) => (
          <MemoRow key={memo.id} memo={memo} topicID={topic.id} target={target} />
        ))}
      </div>
      <section className="evidence" aria-label="Supporting evidence">
        <h3 className="evidence-title">Supporting evidence</h3>
        {turns.length === 0 ? (
          <p className="empty">No committed speech is linked to this topic yet.</p>
        ) : (
          <ol className="turns">
            {turns.map((turn) => (
              <TurnLine key={turn.id} turn={turn} />
            ))}
          </ol>
        )}
      </section>
    </section>
  );
}
