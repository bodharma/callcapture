import { useEffect, useRef, useState } from "react";
import { errorText } from "../../api/client";
import type { LiveSnapshot } from "../../api/liveTypes";
import { seg, useLiveAction, type LiveTarget } from "./api";
import { LiveHeader } from "./LiveHeader";
import { LiveTranscript } from "./LiveTranscript";
import { MemoPanel } from "./MemoPanel";
import { NoteComposer } from "./NoteComposer";
import { topicByID } from "./liveFormat";
import { TopicOutline } from "./TopicOutline";
import "./live.css";

interface FullLiveProps {
  view: LiveSnapshot;
  target: LiveTarget;
  online: boolean | undefined;
}

type BottomTab = "transcript" | "warnings";

function AddTopic({ target }: { target: LiveTarget }) {
  const [title, setTitle] = useState("");
  const add = useLiveAction(target);
  return (
    <form
      className="live-add-topic"
      onSubmit={(event) => {
        event.preventDefault();
        if (title.trim() === "") return;
        add.mutate({ path: "topics", body: { title } }, { onSuccess: () => setTitle("") });
      }}
    >
      <label className="visually-hidden" htmlFor="new-topic">
        New topic title
      </label>
      <input
        id="new-topic"
        className="field"
        value={title}
        maxLength={200}
        placeholder="New topic title"
        onChange={(event) => setTitle(event.target.value)}
      />
      <button type="submit" className="btn btn--small" disabled={title.trim() === "" || add.isPending}>
        Add topic
      </button>
      {add.isError && (
        <p className="live-error" role="alert">
          {errorText(add.error)}
        </p>
      )}
    </form>
  );
}

/** The live workspace's ⌘⇧J / ⌘⇧N / ⌘⇧L shortcuts, while the meeting runs. */
function useShortcuts(enabled: boolean, actions: Record<"j" | "n" | "l", () => void>) {
  const latest = useRef(actions);
  latest.current = actions;
  useEffect(() => {
    if (!enabled) return;
    const onKey = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || !event.shiftKey) return;
      const key = event.key.toLowerCase() as "j" | "n" | "l";
      if (!(key in latest.current)) return;
      event.preventDefault();
      latest.current[key]();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [enabled]);
}

/**
 * The full live layout (`/live`, `/sessions/:id/live`): every action of the SwiftUI
 * live workspace. The meeting being recorded keeps its selection in the app (shared by
 * every host); a saved map keeps it in the page.
 */
export function FullLive({ view, target, online }: FullLiveProps) {
  const saved = target.kind === "session";
  const [pageSelection, setPageSelection] = useState<string>();
  const [tab, setTab] = useState<BottomTab>("transcript");
  const composer = useRef<HTMLTextAreaElement | HTMLInputElement | null>(null);
  const select = useLiveAction(target);
  const shortcutAction = useLiveAction(target);

  const fallback = view.currentTopicID ?? view.topics[0]?.id;
  const selectedID = saved
    ? (topicByID(view, pageSelection)?.id ?? fallback)
    : (topicByID(view, view.selectedTopicID)?.id ?? fallback);
  const selected = topicByID(view, selectedID);
  const lastWarning = view.warnings.at(-1);

  useShortcuts(view.active, {
    j: () => shortcutAction.mutate({ path: "catch-up" }),
    n: () => composer.current?.focus(),
    l: () => shortcutAction.mutate({ path: "back-to-live" }),
  });

  return (
    <div className="live">
      <LiveHeader view={view} target={target} onAddThought={() => composer.current?.focus()} />
      {view.active && !view.followsLive && (
        <p className="notice">
          Browsing earlier evidence · live transcript continues ({view.turns.length} committed turns)
        </p>
      )}
      {view.catchUpText && (
        <section className="live-catchup" aria-label="Catch up">
          <h2 className="live-section-title">Catch up</h2>
          <p>{view.catchUpText}</p>
        </section>
      )}
      {view.active && online === false && (
        <div className="notice notice--warn">
          <p>{view.offlineMessage}</p>
          <p>Catch-up shows the original speech; the recap waits for internet.</p>
        </div>
      )}
      {view.error && (
        <p className="notice notice--warn" role="alert">
          {view.error}
        </p>
      )}
      {lastWarning && <p className="notice">{lastWarning}</p>}
      {(select.error ?? shortcutAction.error) && (
        <p className="live-error" role="alert">
          {errorText(select.error ?? shortcutAction.error)}
        </p>
      )}
      <AddTopic target={target} />
      <div className="live-split">
        <TopicOutline
          topics={view.topics}
          selectedID={selectedID}
          currentID={view.currentTopicID}
          live={view.active}
          onSelect={(id) =>
            saved ? setPageSelection(id) : select.mutate({ path: `topics/${seg(id)}/select` })
          }
        />
        <MemoPanel view={view} topic={selected} target={target} />
      </div>
      <section className="live-composer" aria-label="Add a note">
        <NoteComposer target={target} topicID={saved ? selectedID : undefined} inputRef={composer} />
      </section>
      <div className="tabs live-tabs" role="tablist" aria-label="Transcript">
        <button
          type="button"
          role="tab"
          id="live-tab-transcript"
          aria-controls="live-panel"
          aria-selected={tab === "transcript"}
          onClick={() => setTab("transcript")}
        >
          Transcript · {view.turns.length} committed turns
        </button>
        <button
          type="button"
          role="tab"
          id="live-tab-warnings"
          aria-controls="live-panel"
          aria-selected={tab === "warnings"}
          onClick={() => setTab("warnings")}
        >
          Warnings · {view.warnings.length}
        </button>
      </div>
      <div id="live-panel" role="tabpanel" aria-labelledby={`live-tab-${tab}`} className="live-panel">
        {tab === "transcript" ? (
          <LiveTranscript view={view} />
        ) : view.warnings.length === 0 ? (
          <p className="empty">No gaps or warnings in this live map.</p>
        ) : (
          <ul className="live-warnings">
            {view.warnings.map((warning, index) => (
              <li key={`${index}-${warning}`}>{warning}</li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
