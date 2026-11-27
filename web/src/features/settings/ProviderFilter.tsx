import { useEffect, useId, useRef, useState } from "react";
import { providerName, type ProviderOption } from "./modelFilters";

interface ProviderFilterProps {
  options: readonly ProviderOption[];
  chosen: readonly string[];
  onChange: (chosen: string[]) => void;
}

/** A disclosure button over a filterable, scrollable checklist that opens in the page flow: the catalog has dozens of providers. */
export function ProviderFilter({ options, chosen, onChange }: ProviderFilterProps) {
  const panelId = useId();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const button = useRef<HTMLButtonElement>(null);
  const root = useRef<HTMLDivElement>(null);
  const needle = query.trim().toLocaleLowerCase();
  // A chosen provider with no models in view stays listed (at zero) so it can be unticked.
  const listed = [
    ...options,
    ...chosen
      .filter((id) => !options.some((option) => option.id === id))
      .map((id) => ({ id, name: providerName(id), count: 0 })),
  ];
  const shown = listed.filter(
    (option) => needle === "" || option.name.toLocaleLowerCase().includes(needle) || option.id.includes(needle),
  );

  const close = () => {
    setOpen(false);
    button.current?.focus();
  };
  // A press outside closes it without moving focus: the press already put focus where it belongs.
  useEffect(() => {
    if (!open) return;
    const onPress = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("pointerdown", onPress);
    return () => document.removeEventListener("pointerdown", onPress);
  }, [open]);
  const toggle = (id: string, on: boolean) =>
    onChange(on ? [...chosen, id] : chosen.filter((entry) => entry !== id));

  return (
    <div
      ref={root}
      className="provider-filter"
      onBlur={(event) => {
        const next = event.relatedTarget as Node | null;
        if (open && next && !event.currentTarget.contains(next)) setOpen(false);
      }}
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
