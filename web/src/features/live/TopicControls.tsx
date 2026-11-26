import { useState } from "react";
import { errorText } from "../../api/client";
import type { LiveTopic } from "../../api/liveTypes";
import { seg, useLiveAction, type LiveTarget } from "./api";

const MAX_TITLE = 200;

interface TopicControlsProps {
  topic: LiveTopic;
  topics: LiveTopic[];
  target: LiveTarget;
}

function ActionError({ error }: { error: unknown }) {
  return (
    <p className="live-error" role="alert">
      {errorText(error)}
    </p>
  );
}

/** Rename, move under another topic (or to the top level) and merge into another topic. */
export function TopicControls({ topic, topics, target }: TopicControlsProps) {
  const [title, setTitle] = useState("");
  const [parent, setParent] = useState(topic.parentID ?? "");
  const [mergeTarget, setMergeTarget] = useState("");
  const rename = useLiveAction(target);
  const move = useLiveAction(target);
  const merge = useLiveAction(target);
  const others = topics.filter((other) => other.id !== topic.id);
  const base = `topics/${seg(topic.id)}`;

  return (
    <div className="topic-controls">
      <form
        className="topic-control"
        onSubmit={(event) => {
          event.preventDefault();
          if (title.trim() === "") return;
          rename.mutate({ path: `${base}/rename`, body: { title } }, { onSuccess: () => setTitle("") });
        }}
      >
        <label className="visually-hidden" htmlFor={`rename-${topic.id}`}>
          New title for {topic.title}
        </label>
        <input
          id={`rename-${topic.id}`}
          className="field"
          value={title}
          maxLength={MAX_TITLE}
          placeholder="New topic title"
          onChange={(event) => setTitle(event.target.value)}
        />
        <button type="submit" className="btn btn--small" disabled={title.trim() === "" || rename.isPending}>
          Rename
        </button>
        {rename.isError && <ActionError error={rename.error} />}
      </form>

      <div className="topic-control">
        <label className="visually-hidden" htmlFor={`move-${topic.id}`}>
          Move {topic.title} under
        </label>
        <select id={`move-${topic.id}`} className="field" value={parent} onChange={(event) => setParent(event.target.value)}>
          <option value="">Top level</option>
          {others.map((other) => (
            <option key={other.id} value={other.id}>
              {other.title}
            </option>
          ))}
        </select>
        <button
          type="button"
          className="btn btn--small"
          disabled={move.isPending}
          onClick={() => move.mutate({ path: `${base}/move`, body: { parentID: parent === "" ? null : parent } })}
        >
          Move
        </button>
        {move.isError && <ActionError error={move.error} />}
      </div>

      <div className="topic-control">
        <label className="visually-hidden" htmlFor={`merge-${topic.id}`}>
          Merge {topic.title} into
        </label>
        <select
          id={`merge-${topic.id}`}
          className="field"
          value={mergeTarget}
          disabled={others.length === 0}
          onChange={(event) => setMergeTarget(event.target.value)}
        >
          <option value="" disabled>
            Merge into…
          </option>
          {others.map((other) => (
            <option key={other.id} value={other.id}>
              {other.title}
            </option>
          ))}
        </select>
        <button
          type="button"
          className="btn btn--small"
          disabled={mergeTarget === "" || merge.isPending}
          onClick={() =>
            merge.mutate({ path: `${base}/merge`, body: { targetID: mergeTarget } }, { onSuccess: () => setMergeTarget("") })
          }
        >
          Merge
        </button>
        {others.length === 0 && <span className="live-hint">Add another topic to merge into.</span>}
        {merge.isError && <ActionError error={merge.error} />}
      </div>
    </div>
  );
}
