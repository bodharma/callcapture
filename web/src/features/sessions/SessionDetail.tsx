import type { UseQueryResult } from "@tanstack/react-query";
import { useEffect } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { ApiError, errorText } from "../../api/client";
import type { SessionDTO, TranscriptLine } from "../../api/types";
import { useSession, useSessionPart, useSystem } from "./api";
import { DetailFields, TranscribeProgress } from "./DetailFields";
import { FileActions } from "./FileActions";
import { Notices } from "./Notices";
import { PlayerProvider, usePlayer } from "./player";
import { SessionActions } from "./SessionActions";
import { Speakers } from "./Speakers";
import { Summary } from "./Summary";
import { TapeSection } from "./TapeSection";
import { Transcript } from "./Transcript";

const TABS = [
  { id: "summary", label: "Summary" },
  { id: "transcript", label: "Transcript" },
  { id: "topics", label: "Topic map" },
  { id: "speakers", label: "Speakers" },
] as const;
type Tab = (typeof TABS)[number]["id"];

const parseTab = (value: string | null): Tab => TABS.find((tab) => tab.id === value)?.id ?? "summary";

function parseTime(value: string | null): number | undefined {
  const time = value === null ? Number.NaN : Number(value);
  return Number.isFinite(time) && time >= 0 ? time : undefined;
}

/** `/sessions/:id`. One player per session, so switching sessions starts fresh. */
export function SessionDetail() {
  const { id = "" } = useParams();
  return (
    <PlayerProvider key={id}>
      <SessionView id={id} />
    </PlayerProvider>
  );
}

function SessionView({ id }: { id: string }) {
  const [params] = useSearchParams();
  const tab = parseTab(params.get("tab"));
  const focusTime = parseTime(params.get("t"));
  const query = useSession(id);
  const system = useSystem();
  const player = usePlayer();

  // A search hit opens the session at its moment: positioned, not playing.
  useEffect(() => {
    if (focusTime !== undefined) player.seek(focusTime);
  }, [focusTime, player]);

  if (query.isPending) return <p className="empty" aria-busy="true">Loading the session…</p>;
  if (query.isError) {
    const gone = query.error instanceof ApiError && query.error.status === 404;
    return (
      <div className="empty">
        <p>
          {gone
            ? "This session isn't there any more. It may have been deleted."
            : `This session couldn't be loaded. ${errorText(query.error)}`}
        </p>
        {gone ? (
          <Link to="/sessions">Back to sessions</Link>
        ) : (
          <button type="button" className="btn btn--small" onClick={() => void query.refetch()}>
            Try again
          </button>
        )}
      </div>
    );
  }

  return (
    <SessionBody session={query.data} tab={tab} focusTime={focusTime} recording={system.data?.recording ?? false} />
  );
}

interface SessionBodyProps {
  session: SessionDTO;
  tab: Tab;
  focusTime?: number;
  recording: boolean;
}

function SessionBody({ session, tab, focusTime, recording }: SessionBodyProps) {
  const { id } = session;
  const analysis = useSessionPart(id, "analysis", session.hasAnalysis);
  const note = useSessionPart(id, "note", session.hasNote && tab === "summary");
  const markers = useSessionPart(id, "markers", session.hasLiveMap);
  const speakers = useSessionPart(id, "speakers", session.hasTranscript || session.hasAnalysis);
  const transcript = useSessionPart(id, "transcript", session.hasTranscript && tab === "transcript");
  const partError = [analysis, note, markers, speakers].find((part) => part.isError)?.error;

  return (
    <article className="detail">
      <header className="detail-head">
        <div className="detail-titles">
          <h1 className="detail-title">{session.title}</h1>
          <DetailFields session={session} />
          <TranscribeProgress session={session} />
        </div>
        <SessionActions session={session} />
      </header>

      <TapeSection session={session} markers={markers.data ?? []} recording={recording} />
      <Notices session={session} analysisWarnings={analysis.data?.warnings ?? []} />

      <nav className="tabs" aria-label="Session sections">
        {TABS.map(({ id: tabId, label }) => (
          <Link key={tabId} to={`?tab=${tabId}`} aria-current={tab === tabId ? "page" : undefined}>
            {label}
          </Link>
        ))}
      </nav>

      {partError !== undefined && tab !== "transcript" && (
        <p className="notice notice--warn">Part of this session couldn't be loaded. {errorText(partError)}</p>
      )}

      {tab === "summary" && (
        <Summary
          status={session.status}
          analysis={analysis.data}
          note={note.data?.markdown}
          markers={markers.data ?? []}
          speakers={speakers.data ?? []}
          noteSessionId={session.hasNote ? id : undefined}
        />
      )}
      {tab === "transcript" && <TranscriptTab session={session} query={transcript} focusTime={focusTime} />}
      {tab === "topics" && <TopicsTab session={session} />}
      {tab === "speakers" && (
        <Speakers sessionId={id} speakers={speakers.data ?? []} stats={analysis.data?.speakers ?? []} />
      )}

      <FileActions session={session} />
    </article>
  );
}

interface TranscriptTabProps {
  session: SessionDTO;
  query: UseQueryResult<TranscriptLine[]>;
  focusTime?: number;
}

function TranscriptTab({ session, query, focusTime }: TranscriptTabProps) {
  if (!session.hasTranscript) {
    return (
      <p className="empty">
        {session.status === "transcribing"
          ? "Transcribing. The transcript shows up here when it's ready."
          : "No transcript yet. Transcribe the session to get one."}
      </p>
    );
  }
  if (query.isPending) return <p className="empty" aria-busy="true">Loading the transcript…</p>;
  if (query.isError) {
    return <p className="notice notice--warn">The transcript couldn't be loaded. {errorText(query.error)}</p>;
  }
  return <Transcript sessionId={session.id} lines={query.data} focusTime={focusTime} />;
}

function TopicsTab({ session }: { session: SessionDTO }) {
  if (!session.hasLiveMap) {
    return <p className="empty">This session was recorded without the live map, so it has no topic map.</p>;
  }
  return (
    <div className="topics">
      <p>The topic map shows what was talked about and how the conversation moved between topics.</p>
      <Link to={`/sessions/${encodeURIComponent(session.id)}/live`}>Open the topic map</Link>
    </div>
  );
}
