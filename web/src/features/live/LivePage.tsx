import type { UseQueryResult } from "@tanstack/react-query";
import { Link } from "react-router";
import { errorText } from "../../api/client";
import { isSnapshot, type LiveResponse } from "../../api/liveTypes";
import { ConnectionStatus, TopBar } from "../../components/TopBar";
import { RecordControl } from "../../components/RecordControl";
import { useSystem } from "../sessions/api";
import "../sessions/sessions.css";
import { currentTarget, useLive } from "./api";
import { CompactLive } from "./CompactLive";
import { FullLive } from "./FullLive";
import { useCompact } from "./useCompact";
import "./compact.css";
import "./live.css";

interface LiveContentProps {
  query: UseQueryResult<LiveResponse>;
  compact: boolean;
  online: boolean | undefined;
}

function LiveContent({ query, compact, online }: LiveContentProps) {
  if (query.isPending) return <p className="empty" aria-busy="true">Loading the live map…</p>;
  if (query.isError && !query.data) {
    return (
      <div className="empty">
        <p>The live map couldn't be loaded. {errorText(query.error)}</p>
        <button type="button" className="btn btn--small" onClick={() => void query.refetch()}>
          Try again
        </button>
      </div>
    );
  }
  const live = query.data;
  if (!isSnapshot(live)) {
    return (
      <div className="live-idle">
        <p className="empty">
          No live meeting is running. Start a recording with the live map turned on from the menu bar.
        </p>
        {live?.lastSessionID && (
          <Link to={`/sessions/${encodeURIComponent(live.lastSessionID)}/live`}>Open the last meeting's map</Link>
        )}
      </div>
    );
  }
  return compact ? <CompactLive view={live} online={online} /> : <FullLive view={live} target={currentTarget} online={online} />;
}

/**
 * `/live`: the meeting being recorded. Full layout in the archive window and the
 * browser; compact layout in the floating panel (`?compact=1`) or any window ≤ 480 px.
 */
export function LivePage() {
  const compact = useCompact();
  const live = useLive();
  const online = useSystem().data?.online;

  if (compact) {
    const title = isSnapshot(live.data) ? live.data.title : "Live meeting";
    return (
      <div className="compact">
        <header className="compact-head">
          <span className="compact-title">{title || "Live meeting"}</span>
          <RecordControl compact />
        </header>
        <div className="compact-status">
          <ConnectionStatus />
        </div>
        <LiveContent query={live} compact online={online} />
      </div>
    );
  }
  return (
    <div className="archive">
      <TopBar />
      <main className="live-main">
        <LiveContent query={live} compact={false} online={online} />
      </main>
    </div>
  );
}
