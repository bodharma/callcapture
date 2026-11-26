import { errorText } from "../../api/client";
import type { LiveSnapshot, LiveSource } from "../../api/liveTypes";
import { timecode } from "../../lib/format";
import { currentTarget, useLiveAction } from "./api";
import { channelLines, memoTag, speaker, topicByID, topicParentTitle, usageLine } from "./liveFormat";
import { NoteComposer } from "./NoteComposer";

const LATEST_MEMOS = 3;
const SOURCES: readonly LiveSource[] = ["system", "mic"];

/** What is being said now: partial speech if any, else the last committed turn. */
function NowLine({ view }: { view: LiveSnapshot }) {
  const partial = SOURCES.map((source) => ({ source, text: view.partials[source] })).find((entry) => entry.text);
  if (partial?.text) {
    return <p className="compact-now compact-now--partial">{`${speaker(partial.source, true)} · ${partial.text}`}</p>;
  }
  const last = view.turns.at(-1);
  if (!last) return <p className="compact-now empty">Listening for speech.</p>;
  return (
    <p className="compact-now">
      {`${speaker(last.source, true)} · ${last.text}`}
      <span className="compact-at"> at {timecode(last.start)}</span>
    </p>
  );
}

/**
 * The floating panel's layout (≤ 480 px): the current topic, its latest memos, the
 * line being spoken, channel status, spend and the note composer. No transcript tabs.
 */
export function CompactLive({ view, online }: { view: LiveSnapshot; online: boolean | undefined }) {
  const catchUp = useLiveAction(currentTarget);
  const backToLive = useLiveAction(currentTarget);
  const topic = topicByID(view, view.selectedTopicID) ?? topicByID(view, view.currentTopicID);
  const parent = topic ? topicParentTitle(view, topic) : undefined;
  const memos = topic?.memos.slice(-LATEST_MEMOS) ?? [];
  const actionError = catchUp.error ?? backToLive.error;

  return (
    <div className="compact-body">
      {!view.followsLive && (
        <div className="compact-browse">
          <span>Reading {topic?.title ?? "an earlier topic"}. The live map moved on.</span>
          <span className="compact-browse-actions">
            <button type="button" className="btn btn--small" onClick={() => catchUp.mutate({ path: "catch-up" })}>
              Catch up
            </button>
            <button
              type="button"
              className="btn btn--small btn--primary"
              onClick={() => backToLive.mutate({ path: "back-to-live" })}
            >
              Back to live
            </button>
          </span>
        </div>
      )}
      {actionError && (
        <p className="live-error" role="alert">
          {errorText(actionError)}
        </p>
      )}
      {view.catchUpText && <p className="compact-catchup">{view.catchUpText}</p>}
      {online === false && <p className="notice notice--warn">{view.offlineMessage}</p>}
      {view.error && <p className="notice notice--warn">{view.error}</p>}

      <section className="compact-section" aria-label="Now on">
        <span className="compact-label">Now on</span>
        <h1 className="compact-heading">
          {parent && <span className="compact-parent">{parent} / </span>}
          <span className="compact-topic">{topic?.title ?? "Waiting for committed speech"}</span>
        </h1>
        {memos.length > 0 && (
          <dl className="compact-memos">
            {memos.map((memo) => {
              const tag = memoTag(memo);
              return (
                <div key={memo.id} className="compact-memo">
                  <dt className={`compact-tag compact-tag--${tag.tone}`}>{tag.text}</dt>
                  <dd>{memo.text}</dd>
                </div>
              );
            })}
          </dl>
        )}
        <NowLine view={view} />
      </section>

      <section className="compact-section compact-readouts" aria-label="Channels">
        {channelLines(view).map((line) => (
          <span key={line}>{line}</span>
        ))}
        {view.usage && <span>{usageLine(view.usage)}</span>}
      </section>

      <div className="compact-spacer" />
      <NoteComposer target={currentTarget} compact />
    </div>
  );
}
