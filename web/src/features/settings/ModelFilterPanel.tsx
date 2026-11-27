import { useId, type ReactNode } from "react";
import { ProviderFilter } from "./ProviderFilter";
import { providersOf, tagsOf, type CostRole, type ModelFilters } from "./modelFilters";
import type { CatalogModel } from "./types";

const COST_LIMITS = [0.01, 0.1, 0.5, 1, 5, 10];
const MULTILINGUAL_MINIMUMS = [0.5, 0.6, 0.7, 0.8, 0.9];
const CONTEXTS = [
  { value: 32_000, label: "32k or more" },
  { value: 128_000, label: "128k or more" },
  { value: 200_000, label: "200k or more" },
  { value: 1_000_000, label: "1M or more" },
];

interface PanelProps {
  models: readonly CatalogModel[];
  /** The models a provider can be chosen from: independent of the other filters. */
  providerModels: readonly CatalogModel[];
  filters: ModelFilters;
  costRole: CostRole;
  shown: number;
  canClear: boolean;
  onChange: (filters: ModelFilters) => void;
  onCostRole: (role: CostRole) => void;
  onClear: () => void;
}

/** "" is the "any" option; otherwise the option's number. */
const numberOrUndefined = (value: string): number | undefined => (value === "" ? undefined : Number(value));

function toggled(list: readonly string[], item: string, on: boolean): string[] {
  return on ? [...list, item] : list.filter((entry) => entry !== item);
}

/** Native controls that narrow the model table, with the count of what is left. */
export function ModelFilterPanel({
  models,
  providerModels,
  filters,
  costRole,
  shown,
  canClear,
  onChange,
  onCostRole,
  onClear,
}: PanelProps) {
  const set = (change: Partial<ModelFilters>) => onChange({ ...filters, ...change });
  const tags = tagsOf(models);
  return (
    <div className="filters">
      <div className="filter-row">
        <ProviderFilter
          options={providersOf(providerModels)}
          chosen={filters.providers}
          onChange={(providers) => set({ providers })}
        />
        {tags.length > 0 && (
          <CheckGroup
            legend="Good for"
            items={tags}
            chosen={filters.goodFor}
            onToggle={(item, on) => set({ goodFor: toggled(filters.goodFor, item, on) })}
          />
        )}
      </div>
      <div className="filter-row">
        <FilterSelect
          label="Cost for"
          value={costRole}
          onChange={(value) => onCostRole(value === "final" ? "final" : "live")}
        >
          <option value="live">Live notes</option>
          <option value="final">Final notes</option>
        </FilterSelect>
        <FilterSelect
          label="Max cost per hour"
          value={filters.maxCostPerHour?.toString() ?? ""}
          onChange={(value) => set({ maxCostPerHour: numberOrUndefined(value) })}
        >
          <option value="">Any</option>
          {COST_LIMITS.map((limit) => (
            <option key={limit} value={limit}>{`Up to $${limit} per hour`}</option>
          ))}
        </FilterSelect>
        <FilterSelect
          label="Ukrainian quality"
          value={filters.minMultilingual?.toString() ?? ""}
          onChange={(value) => set({ minMultilingual: numberOrUndefined(value) })}
        >
          <option value="">Any</option>
          {MULTILINGUAL_MINIMUMS.map((minimum) => (
            <option key={minimum} value={minimum}>{`Multilingual ${minimum.toFixed(1)} or higher`}</option>
          ))}
        </FilterSelect>
        <label className="toggle">
          <input
            type="checkbox"
            checked={filters.includeUnscored}
            disabled={filters.minMultilingual === undefined}
            onChange={(event) => set({ includeUnscored: event.target.checked })}
          />
          <span>Include models without a score</span>
        </label>
        <FilterSelect
          label="Context length"
          value={filters.minContext?.toString() ?? ""}
          onChange={(value) => set({ minContext: numberOrUndefined(value) })}
        >
          <option value="">Any</option>
          {CONTEXTS.map((context) => (
            <option key={context.value} value={context.value}>
              {context.label}
            </option>
          ))}
        </FilterSelect>
      </div>
      <div className="filter-row filter-summary">
        <span role="status">{`Showing ${shown} of ${models.length} models`}</span>
        <button type="button" className="link-button" disabled={!canClear} onClick={onClear}>
          Clear filters
        </button>
      </div>
    </div>
  );
}

interface SelectProps {
  label: string;
  value: string;
  onChange: (value: string) => void;
  children: ReactNode;
}

function FilterSelect({ label, value, onChange, children }: SelectProps) {
  const id = useId();
  return (
    <div className="filter-field">
      <label htmlFor={id}>{label}</label>
      <select id={id} className="filter-select" value={value} onChange={(event) => onChange(event.target.value)}>
        {children}
      </select>
    </div>
  );
}

interface CheckGroupProps {
  legend: string;
  items: readonly string[];
  chosen: readonly string[];
  onToggle: (item: string, on: boolean) => void;
}

function CheckGroup({ legend, items, chosen, onToggle }: CheckGroupProps) {
  return (
    <div role="group" aria-label={legend} className="filter-group">
      <span className="filter-legend" aria-hidden="true">
        {legend}
      </span>
      <div className="filter-checks">
        {items.map((item) => (
          <label key={item} className="toggle">
            <input
              type="checkbox"
              checked={chosen.includes(item)}
              onChange={(event) => onToggle(item, event.target.checked)}
            />
            <span>{item}</span>
          </label>
        ))}
      </div>
    </div>
  );
}
