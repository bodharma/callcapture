import { filterModels, type CostRole, type ModelFilters } from "./modelFilters";
import type { CatalogModel } from "./types";

export type SortColumn = "name" | "live" | "final" | "intelligence" | "multilingual" | "strategy" | "context";

export interface ModelSort {
  column: SortColumn;
  descending: boolean;
}

export interface TableView {
  query: string;
  /** Only models that return JSON, which automatic live notes need. */
  jsonOnly: boolean;
  sort: ModelSort;
  /** Provider, cost, score, context and tag limits; none when omitted. */
  filters?: ModelFilters;
  /** Which job the cost limit is for. */
  costRole?: CostRole;
}

/** Cheapest live notes first, as the app's picker opens. */
export const DEFAULT_SORT: ModelSort = { column: "live", descending: false };

/** Scores and context read best high-first; names and prices low-first. */
const STARTS_HIGH: ReadonlySet<SortColumn> = new Set(["intelligence", "multilingual", "strategy", "context"]);

type SortValue = string | number | undefined;

function sortValue(model: CatalogModel, column: SortColumn): SortValue {
  switch (column) {
    case "name":
      return model.name.toLocaleLowerCase();
    case "live":
      return model.hourlyUSD.live;
    case "final":
      return model.hourlyUSD.final;
    case "intelligence":
      return model.scores?.intelligence;
    case "multilingual":
      return model.scores?.multilingual;
    case "strategy":
      return model.scores?.strategyAndOps;
    case "context":
      return model.contextLength;
  }
}

/** A stable sort; a missing score sorts below every real score in either direction. */
export function sortModels(models: readonly CatalogModel[], sort: ModelSort): CatalogModel[] {
  const direction = sort.descending ? -1 : 1;
  return [...models].sort((a, b) => {
    const x = sortValue(a, sort.column);
    const y = sortValue(b, sort.column);
    if (x === undefined || y === undefined) return x === y ? 0 : x === undefined ? 1 : -1;
    if (x < y) return -direction;
    if (x > y) return direction;
    return 0;
  });
}

export function visibleModels(models: readonly CatalogModel[], view: TableView): CatalogModel[] {
  const query = view.query.trim().toLocaleLowerCase();
  const limited = view.filters ? filterModels(models, view.filters, view.costRole ?? "live") : models;
  const matching = limited.filter(
    (model) =>
      (!view.jsonOnly || model.supportsJSON) &&
      (query === "" || model.name.toLocaleLowerCase().includes(query) || model.id.toLocaleLowerCase().includes(query)),
  );
  return sortModels(matching, view.sort);
}

/** The same column flips direction; a new column starts in its natural direction. */
export function toggleSort(current: ModelSort, column: SortColumn): ModelSort {
  if (current.column === column) return { column, descending: !current.descending };
  return { column, descending: STARTS_HIGH.has(column) };
}

/** USD per meeting hour, formatted like the app's picker. */
export function perHour(value: number): string {
  if (value === 0) return "free";
  if (value < 0.01) return `$${value.toFixed(4)}`;
  if (value < 10) return `$${value.toFixed(2)}`;
  return `$${value.toFixed(0)}`;
}

/** How many of ten bar segments a score fills. */
export function scoreSegments(value: number, max: number): number {
  return Math.max(0, Math.min(10, Math.round((value / max) * 10)));
}
