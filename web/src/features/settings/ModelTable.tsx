import { useId, useMemo, useState } from "react";
import { errorText } from "../../api/client";
import { useRefreshCatalog, useSaveSetting } from "./api";
import { OfflineReason } from "./controls";
import { DEFAULT_SORT, perHour, scoreSegments, toggleSort, visibleModels, type SortColumn } from "./modelSort";
import type { CatalogDTO, CatalogModel } from "./types";
import "./ModelTable.css";

type Role = "live" | "final";

interface TableProps {
  catalog: CatalogDTO;
  liveModel: string;
  finalModel: string;
  online: boolean | undefined;
  offlineReason: string;
}

const listDate = new Intl.DateTimeFormat("en-GB", {
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

/** "26 Nov, 14:58" */
function listedAt(iso: string): string {
  const parts = listDate.formatToParts(new Date(iso));
  const part = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return `${part("day")} ${part("month")}, ${part("hour")}:${part("minute")}`;
}

/**
 * OpenRouter's models with per-hour costs and independent scores, cheapest live notes
 * first and JSON-capable only until the filter is cleared, as the app's picker opens.
 * Each row sets the live or final notes model.
 */
export function ModelTable({ catalog, liveModel, finalModel, online, offlineReason }: TableProps) {
  const searchId = useId();
  const [query, setQuery] = useState("");
  const [jsonOnly, setJsonOnly] = useState(true);
  const [sort, setSort] = useState(DEFAULT_SORT);
  const rows = useMemo(
    () => visibleModels(catalog.models, { query, jsonOnly, sort }),
    [catalog.models, query, jsonOnly, sort],
  );
  const save = useSaveSetting();
  const refresh = useRefreshCatalog();
  const offline = online === false;
  const scored = catalog.models.some((model) => model.scores);

  const choose = (model: CatalogModel, role: Role) =>
    save.mutate({ aiNotes: role === "live" ? { liveModel: model.id } : { finalModel: model.id } });

  return (
    <div className="catalog">
      <div className="catalog-tools">
        <label className="visually-hidden" htmlFor={searchId}>
          Search models
        </label>
        <input
          id={searchId}
          className="search catalog-search"
          type="search"
          value={query}
          placeholder={`Search ${catalog.models.length} models`}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => setQuery(event.target.value)}
        />
        <label className="toggle">
          <input type="checkbox" checked={jsonOnly} onChange={(event) => setJsonOnly(event.target.checked)} />
          <span>Works for live notes</span>
        </label>
        <span className="catalog-status">
          {catalog.fetchedAt ? `List from ${listedAt(catalog.fetchedAt)}.` : "The model list isn't loaded yet."}{" "}
          <button
            type="button"
            className="link-button"
            disabled={offline || refresh.isPending || catalog.refreshing}
            onClick={() => refresh.mutate(true)}
          >
            {refresh.isPending || catalog.refreshing ? "Refreshing…" : "Refresh"}
          </button>
        </span>
      </div>
      {offline && <OfflineReason reason={offlineReason} />}
      {!offline && catalog.problem && <p className="notice notice--warn">{catalog.problem}</p>}
      {refresh.isError && (
        <p className="field-error" role="alert">
          The model list didn't refresh. {errorText(refresh.error)}
        </p>
      )}
      {catalog.scoresProblem && <p className="offline-reason">{catalog.scoresProblem}</p>}
      {save.isError && (
        <p className="field-error" role="alert">
          The model didn't change. {errorText(save.error)}
        </p>
      )}

      <div className="catalog-scroll">
        <table className="catalog-table" aria-label="OpenRouter models">
          <thead>
            <tr>
              <SortHeader column="name" label="Model" sort={sort} onSort={setSort} />
              <SortHeader column="live" label="Live, per hour" sort={sort} onSort={setSort} numeric />
              <SortHeader column="final" label="Final, per hour" sort={sort} onSort={setSort} numeric />
              <SortHeader column="intelligence" label="Quality" sort={sort} onSort={setSort} />
              <SortHeader column="multilingual" label="Multilingual" sort={sort} onSort={setSort} />
              <SortHeader column="strategy" label="Strategy and ops" sort={sort} onSort={setSort} />
              <SortHeader column="context" label="Context" sort={sort} onSort={setSort} numeric />
              <th scope="col" title={catalog.tagRules}>
                Good for
              </th>
              <th scope="col">Use for</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((model) => (
              <ModelRow
                key={model.id}
                model={model}
                live={model.id === liveModel}
                final={model.id === finalModel}
                busy={save.isPending}
                onChoose={choose}
              />
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <p className="empty catalog-empty">No models match.</p>}
      </div>

      <div className="catalog-notes">
        {scored && catalog.attribution && <p>{catalog.attribution}</p>}
        <p>{catalog.costExplanation}</p>
        <p>{catalog.tagRules}</p>
      </div>
    </div>
  );
}

/** Tokens of context: "128k", or "1M" / "1.5M" from a million up. */
export function contextSize(tokens: number): string {
  if (tokens >= 1_000_000) return `${Math.round(tokens / 100_000) / 10}M`;
  return `${Math.round(tokens / 1000)}k`;
}

interface SortHeaderProps {
  column: SortColumn;
  label: string;
  sort: { column: SortColumn; descending: boolean };
  onSort: (sort: { column: SortColumn; descending: boolean }) => void;
  numeric?: boolean;
}

function SortHeader({ column, label, sort, onSort, numeric }: SortHeaderProps) {
  const active = sort.column === column;
  return (
    <th
      scope="col"
      className={numeric ? "num" : undefined}
      aria-sort={active ? (sort.descending ? "descending" : "ascending") : undefined}
    >
      <button type="button" className="sort-button" onClick={() => onSort(toggleSort(sort, column))}>
        {label}
        <span className="sort-mark" aria-hidden="true">
          {active ? (sort.descending ? "▾" : "▴") : ""}
        </span>
      </button>
    </th>
  );
}

interface RowProps {
  model: CatalogModel;
  live: boolean;
  final: boolean;
  busy: boolean;
  onChoose: (model: CatalogModel, role: Role) => void;
}

function ModelRow({ model, live, final, busy, onChoose }: RowProps) {
  return (
    <tr className={live || final ? "model-row model-row--chosen" : "model-row"}>
      <td title={model.id}>
        <span className="model-name">{model.name}</span>
        {live && <span className="role-mark"> live</span>}
        {final && <span className="role-mark"> final</span>}
      </td>
      <td className="num mono">{perHour(model.hourlyUSD.live)}</td>
      <td className="num mono">{perHour(model.hourlyUSD.final)}</td>
      <td>
        <ScoreBar label="Quality" value={model.scores?.intelligence} max={100} />
      </td>
      <td>
        <ScoreBar label="Multilingual" value={model.scores?.multilingual} max={1} fraction />
      </td>
      <td>
        <ScoreBar label="Strategy and ops" value={model.scores?.strategyAndOps} max={100} />
      </td>
      <td className="num mono">{contextSize(model.contextLength)}</td>
      <td className="model-tags">{model.tags.join(", ")}</td>
      <td>
        <span className="use-for">
          <UseButton model={model} role="live" chosen={live} busy={busy} onChoose={onChoose} />
          <UseButton model={model} role="final" chosen={final} busy={busy} onChoose={onChoose} />
        </span>
      </td>
    </tr>
  );
}

interface UseButtonProps {
  model: CatalogModel;
  role: Role;
  chosen: boolean;
  busy: boolean;
  onChoose: (model: CatalogModel, role: Role) => void;
}

function UseButton({ model, role, chosen, busy, onChoose }: UseButtonProps) {
  return (
    <button
      type="button"
      className={chosen ? "btn btn--small use-button use-button--on" : "btn btn--small use-button"}
      aria-label={`Use ${model.name} for ${role} notes`}
      aria-pressed={chosen}
      disabled={busy}
      onClick={() => {
        if (!chosen) onChoose(model, role);
      }}
    >
      {role === "live" ? "Live" : "Final"}
    </button>
  );
}

interface ScoreProps {
  label: string;
  value: number | undefined;
  max: number;
  fraction?: boolean;
}

/** Ten segments, like the canvas; the number is in the tooltip and for screen readers. */
function ScoreBar({ label, value, max, fraction }: ScoreProps) {
  if (value === undefined) {
    return (
      <span className="score-none" title="No independent score">
        —
      </span>
    );
  }
  const filled = scoreSegments(value, max);
  const text = fraction ? value.toFixed(2) : value.toFixed(0);
  return (
    <span className="score" title={`${label}: ${text} (Artificial Analysis)`}>
      <span className="score-bar" aria-hidden="true">
        {Array.from({ length: 10 }, (_, index) => (
          <span key={index} className={index < filled ? "score-seg score-seg--on" : "score-seg"} />
        ))}
      </span>
      <span className="visually-hidden">{text}</span>
    </span>
  );
}
