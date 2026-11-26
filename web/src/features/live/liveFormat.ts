import type { LiveMemo, LiveNotesUsage, LiveSnapshot, LiveSource, LiveTopic } from "../../api/liveTypes";
import { usd } from "../../lib/format";

/** The live workspace's spend line (same wording as the SwiftUI workspace). */
export function usageLine(usage: LiveNotesUsage): string {
  const requests = `${usage.requests} request${usage.requests === 1 ? "" : "s"}`;
  if (usage.unpricedRequests === usage.requests) return `Live notes: ${requests}, cost not reported`;
  const unpriced = usage.unpricedRequests > 0 ? ` (${usage.unpricedRequests} without reported cost)` : "";
  return `Live notes so far: ≈ ${usd(usage.reportedCostUSD)} · ${requests}${unpriced}`;
}

/** "You" / "Remote audio" in the full view; `short` gives "Remote" for the panel. */
export function speaker(source: LiveSource, short = false): string {
  if (source === "mic") return "You";
  return short ? "Remote" : "Remote audio";
}

/** "Your note", "Suggested decision", "Suggested revision · question". */
export function memoLabel(memo: LiveMemo): string {
  if (memo.suggestedRevisionOf) return `Suggested revision · ${memo.kind}`;
  return `${memo.manual ? "Your" : "Suggested"} ${memo.kind}`;
}

export type MemoTone = "decided" | "open" | "mine" | "plain";

/** The panel's short tag for a memo: decided (green), open (amber), mine (rust). */
export function memoTag(memo: LiveMemo): { text: string; tone: MemoTone } {
  if (memo.manual) return { text: "mine", tone: "mine" };
  if (memo.kind === "decision") return { text: "decided", tone: "decided" };
  if (memo.kind === "question") return { text: "open", tone: "open" };
  return { text: memo.kind, tone: "plain" };
}

/** Per-channel connection status text, shown instead of level meters. */
export function channelLines(view: LiveSnapshot): string[] {
  const state = !view.active
    ? "stopped"
    : !view.speechRunning
      ? "not transcribing"
      : /behind/i.test(view.processingStatus)
        ? "behind, recording continues"
        : "listening";
  return [`ch.1 You · ${view.microphoneEnabled ? state : "microphone off"}`, `ch.2 Remote · ${state}`];
}

export function topicByID(view: LiveSnapshot, id: string | undefined): LiveTopic | undefined {
  return id === undefined ? undefined : view.topics.find((topic) => topic.id === id);
}

/** "Release plan / Timing" for a nested topic. */
export function topicParentTitle(view: LiveSnapshot, topic: LiveTopic): string | undefined {
  return topicByID(view, topic.parentID)?.title;
}

export function currentTopicTitle(view: LiveSnapshot): string {
  return topicByID(view, view.currentTopicID)?.title ?? "Waiting for committed speech";
}
