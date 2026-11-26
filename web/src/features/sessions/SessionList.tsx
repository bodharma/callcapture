import { Fragment, useMemo, type KeyboardEvent } from "react";
import { Link, NavLink } from "react-router";
import { errorText } from "../../api/client";
import type { SearchHit, SessionDTO } from "../../api/types";
import { dayGroup, sessionState, shortDate, timecode } from "../../lib/format";
import { highlightParts } from "../../lib/highlight";
import { useSearch, useSessions } from "./api";

/** Up/Down arrows move between the sidebar's links. */
function onArrowKeys(event: KeyboardEvent<HTMLElement>) {
  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
  const links = Array.from(event.currentTarget.querySelectorAll<HTMLAnchorElement>("a[data-nav]"));
  const at = links.indexOf(document.activeElement as HTMLAnchorElement);
  if (at === -1) return;
  event.preventDefault();
  const next = event.key === "ArrowDown" ? Math.min(links.length - 1, at + 1) : Math.max(0, at - 1);
  links[next].focus();
}

const hitLink = (hit: SearchHit): string =>
  hit.time === undefined
    ? `/sessions/${encodeURIComponent(hit.sessionId)}`
    : `/sessions/${encodeURIComponent(hit.sessionId)}?tab=transcript&t=${hit.time}`;

/** The sidebar: search hits (when searching) above the archive, grouped by day. */
export function SessionList({ query }: { query: string }) {
  const sessions = useSessions();
  const searching = query.trim().length >= 2;

  return (
    <nav className="sidebar" aria-label="Sessions" onKeyDown={onArrowKeys}>
      {searching && <SearchHits query={query.trim()} />}
      {sessions.isPending && (
        <p className="sidebar-note" aria-busy="true">
          Loading sessions…
        </p>
      )}
      {sessions.isError && (
        <div className="sidebar-note">
          <p>The session list couldn't be loaded. {errorText(sessions.error)}</p>
          <button type="button" className="btn btn--small" onClick={() => void sessions.refetch()}>
            Try again
          </button>
        </div>
      )}
      {sessions.data && <Archive sessions={sessions.data} />}
    </nav>
  );
}

function SearchHits({ query }: { query: string }) {
  const search = useSearch(query);
  const hits = search.data ?? [];
  let heading: string;
  if (search.isPending) heading = `Searching for “${query}”…`;
  else if (search.isError) heading = `Search failed. ${errorText(search.error)}`;
  else if (hits.length === 0) heading = `Nothing matches “${query}”.`;
  else heading = `${hits.length} ${hits.length === 1 ? "moment matches" : "moments match"} “${query}”`;

  return (
    <section className="hits" aria-label="Search results">
      <p className="sidebar-note" role="status">
        {heading}
      </p>
      {hits.map((hit) => (
        <Link key={hit.id} to={hitLink(hit)} className="hit" data-nav="">
          <span className="hit-head">
            <span className="hit-title">{hit.title}</span>
            {hit.time !== undefined && <span className="hit-time">{timecode(hit.time)}</span>}
          </span>
          <span className="hit-excerpt">
            {highlightParts(hit.excerpt, query).map((part, index) =>
              part.hit ? <mark key={index}>{part.text}</mark> : <Fragment key={index}>{part.text}</Fragment>,
            )}
          </span>
        </Link>
      ))}
    </section>
  );
}

function Archive({ sessions }: { sessions: SessionDTO[] }) {
  const groups = useMemo(() => {
    const now = new Date();
    const byGroup = new Map<string, SessionDTO[]>();
    for (const session of sessions) {
      const group = dayGroup(new Date(session.startedAt), now);
      byGroup.set(group, [...(byGroup.get(group) ?? []), session]);
    }
    return [...byGroup.entries()];
  }, [sessions]);

  return (
    <>
      {groups.map(([group, members]) => (
        <section key={group} className="archive-group" aria-label={group}>
          <h2 className="sidebar-group">{group}</h2>
          <ul className="archive-list">
            {members.map((session) => {
              const state = sessionState(session.status);
              return (
                <li key={session.id}>
                  <NavLink to={`/sessions/${encodeURIComponent(session.id)}`} className="row" data-nav="">
                    <span className="row-date">{shortDate(new Date(session.startedAt))}</span>
                    <span className="row-title">{session.title}</span>
                    <span className={`row-state tone-${state.tone}`}>{state.word}</span>
                  </NavLink>
                </li>
              );
            })}
          </ul>
        </section>
      ))}
    </>
  );
}
