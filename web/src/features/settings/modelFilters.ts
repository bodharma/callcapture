import type { CatalogModel } from "./types";

export type CostRole = "live" | "final";

export interface ModelFilters {
  /** Provider names (the id prefix); empty means every provider. */
  providers: readonly string[];
  /** Highest USD per meeting hour for the role being chosen; undefined means any. */
  maxCostPerHour: number | undefined;
  /** Lowest Artificial Analysis multilingual score (0 to 1); undefined means any. */
  minMultilingual: number | undefined;
  /** With a minimum score set, keep models that have no score. */
  includeUnscored: boolean;
  /** Smallest context window in tokens; undefined means any. */
  minContext: number | undefined;
  /** The app's tags; a model matches when it has any chosen. Empty means every model. */
  goodFor: readonly string[];
}

export const NO_FILTERS: ModelFilters = {
  providers: [],
  maxCostPerHour: undefined,
  minMultilingual: undefined,
  includeUnscored: false,
  minContext: undefined,
  goodFor: [],
};

/** "anthropic/claude-sonnet-5.5" is from "anthropic"; the catalog has no separate provider field. */
export function modelProvider(id: string): string {
  const slash = id.indexOf("/");
  return slash > 0 ? id.slice(0, slash) : id;
}

export function providersOf(models: readonly CatalogModel[]): string[] {
  return [...new Set(models.map((model) => modelProvider(model.id)))].sort();
}

export function tagsOf(models: readonly CatalogModel[]): string[] {
  return [...new Set(models.flatMap((model) => model.tags))].sort();
}

export function filtersActive(filters: ModelFilters): boolean {
  return (
    filters.providers.length > 0 ||
    filters.maxCostPerHour !== undefined ||
    filters.minMultilingual !== undefined ||
    filters.minContext !== undefined ||
    filters.goodFor.length > 0
  );
}

/** Costs and tags come from the app; this only compares them with the chosen limits. */
export function filterModels(
  models: readonly CatalogModel[],
  filters: ModelFilters,
  role: CostRole,
): CatalogModel[] {
  const { providers, maxCostPerHour, minMultilingual, includeUnscored, minContext, goodFor } = filters;
  return models.filter((model) => {
    if (providers.length > 0 && !providers.includes(modelProvider(model.id))) return false;
    if (maxCostPerHour !== undefined && model.hourlyUSD[role] > maxCostPerHour) return false;
    if (minMultilingual !== undefined) {
      const score = model.scores?.multilingual;
      if (score === undefined ? !includeUnscored : score < minMultilingual) return false;
    }
    if (minContext !== undefined && model.contextLength < minContext) return false;
    if (goodFor.length > 0 && !model.tags.some((tag) => goodFor.includes(tag))) return false;
    return true;
  });
}
