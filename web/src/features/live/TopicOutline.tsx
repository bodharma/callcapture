import type { LiveTopic } from "../../api/liveTypes";

interface TopicOutlineProps {
  topics: LiveTopic[];
  selectedID?: string;
  currentID?: string;
  onSelect: (id: string) => void;
}

/** The topic tree: branches in map order, the selected topic marked, the live one tagged. */
export function TopicOutline({ topics, selectedID, currentID, onSelect }: TopicOutlineProps) {
  const known = new Set(topics.map((topic) => topic.id));
  // A topic whose parent is gone still shows, at the top level.
  const roots = topics.filter((topic) => topic.parentID === undefined || !known.has(topic.parentID));

  const branch = (items: LiveTopic[], depth: number, seen: Set<string>) => (
    <ul className={depth === 0 ? "outline" : "outline outline--nested"}>
      {items.map((topic) => {
        const children = seen.has(topic.id) ? [] : topics.filter((child) => child.parentID === topic.id);
        const selected = topic.id === selectedID;
        return (
          <li key={topic.id}>
            <button
              type="button"
              className={`outline-topic${selected ? " outline-topic--selected" : ""}`}
              aria-current={selected ? "true" : undefined}
              onClick={() => onSelect(topic.id)}
            >
              <span className="outline-visits" title="Visits">
                {topic.visits.length}
              </span>
              <span className="outline-title">{topic.title}</span>
              {topic.pinned && <span className="outline-tag">pinned</span>}
              {topic.id === currentID && <span className="outline-tag outline-tag--live">live now</span>}
            </button>
            {children.length > 0 && branch(children, depth + 1, new Set([...seen, topic.id]))}
          </li>
        );
      })}
    </ul>
  );

  return (
    <nav className="topic-outline" aria-label="Topics">
      {topics.length === 0 ? (
        <p className="empty">Topics appear as committed speech and your notes arrive.</p>
      ) : (
        branch(roots, 0, new Set())
      )}
      <p className="outline-legend">number = visits</p>
    </nav>
  );
}
