import { Link, useParams } from "react-router";
import { ApiError, errorText } from "../../api/client";
import { useSystem } from "../sessions/api";
import { useSavedLive } from "./api";
import { FullLive } from "./FullLive";
import "./live.css";

/**
 * `/sessions/:id/live`: a past session's live map in the full layout. Editable where
 * the model allows it (topics, memos, notes, export); live-only actions are hidden.
 */
export function SavedLivePage() {
  const { id = "" } = useParams();
  const saved = useSavedLive(id);
  const online = useSystem().data?.online;
  const back = (
    <Link className="live-back" to={`/sessions/${encodeURIComponent(id)}`}>
      Back to the session
    </Link>
  );

  if (saved.isPending) return <p className="empty" aria-busy="true">Loading the topic map…</p>;
  if (saved.isError && !saved.data) {
    const missing = saved.error instanceof ApiError && saved.error.status === 404;
    return (
      <div className="detail">
        <p className="empty">
          {missing
            ? "This session was recorded without the live map, so it has no topic map."
            : `The topic map couldn't be loaded. ${errorText(saved.error)}`}
        </p>
        {back}
      </div>
    );
  }
  return (
    <div className="detail live-saved">
      {back}
      <FullLive view={saved.data} target={{ kind: "session", id }} online={online} />
    </div>
  );
}
