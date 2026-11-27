import { useId, useRef, useState } from "react";
import type { ProviderOption } from "./modelFilters";

interface ProviderFilterProps {
  options: readonly ProviderOption[];
  chosen: readonly string[];
  onChange: (chosen: string[]) => void;
}

/** A disclosure button over a filterable, scrollable checklist: the catalog has dozens of providers. */
export function ProviderFilter({ options, chosen, onChange }: ProviderFilterProps) {
  const panelId = useId();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const button = useRef<HTMLButtonElement>(null);
  const needle = query.trim().toLocaleLowerCase();
  const shown = options.filter(
    (option) => needle === "" || option.name.toLocaleLowerCase().includes(needle) || option.id.includes(needle),
  );

  const close = () => {
    setOpen(false);
    button.current?.focus();
  };
  const toggle = (id: string, on: boolean) =>
    onChange(on ? [...chosen, id] : chosen.filter((entry) => entry !== id));

  return (
    <div
      className="provider-filter"
      onKeyDown={(event) => {
        if (event.key === "Escape" && open) {
          event.stopPropagation();
          close();
        }
      }}
    >
      <button
        ref={button}
        type="button"
        className="filter-select provider-button"
        aria-expanded={open}
        aria-controls={open ? panelId : undefined}
        onClick={() => setOpen(!open)}
      >
        {chosen.length > 0 ? `Provider · ${chosen.length} selected` : "Provider"}
        <span aria-hidden="true">{open ? " ▴" : " ▾"}</span>
      </button>
      {open && (
        <div id={panelId} role="group" aria-label="Provider" className="provider-panel">
          <div className="provider-tools">
            <input
              type="text"
              className="search"
              aria-label="Filter providers"
              placeholder="Filter providers"
              autoComplete="off"
              spellCheck={false}
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            <button type="button" className="link-button" disabled={chosen.length === 0} onClick={() => onChange([])}>
              Select none
            </button>
          </div>
          <div className="provider-list">
            {shown.map((option) => (
              <label key={option.id} className="toggle">
                <input
                  type="checkbox"
                  checked={chosen.includes(option.id)}
                  onChange={(event) => toggle(option.id, event.target.checked)}
                />
                <span>{option.name}</span>
                <span className="provider-count" aria-hidden="true">
                  {option.count}
                </span>
              </label>
            ))}
            {shown.length === 0 && <p className="provider-none">No providers match.</p>}
          </div>
        </div>
      )}
    </div>
  );
}
