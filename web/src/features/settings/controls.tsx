import { useEffect, useId, useState, type ReactNode } from "react";
import { errorText } from "../../api/client";
import { useSaveSetting } from "./api";
import type { SettingsPatch } from "./types";

export interface Option {
  value: string;
  label: string;
}

/** Pane title and one-line lead, as on the canvas. */
export function PaneHeader({ title, lead }: { title: string; lead: ReactNode }) {
  return (
    <header className="pane-head">
      <h1>{title}</h1>
      <p className="pane-lead">{lead}</p>
    </header>
  );
}

export function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="settings-section" aria-label={title}>
      <h2>{title}</h2>
      {children}
    </section>
  );
}

/** A failed save, said as a sentence under the control. */
export function FieldError({ id, error }: { id: string; error: unknown }) {
  if (!error) return null;
  return (
    <p id={id} className="field-error" role="alert">
      {typeof error === "string" ? error : errorText(error)}
    </p>
  );
}

/** Why a network control is off, in the app's wording. */
export function OfflineReason({ reason }: { reason: string }) {
  return <p className="offline-reason">{reason}</p>;
}

interface RowProps {
  label: string;
  htmlFor?: string;
  hint?: ReactNode;
  hintId?: string;
  children: ReactNode;
}

/** Label on the left, control with its hint and messages on the right. */
export function SettingRow({ label, htmlFor, hint, hintId, children }: RowProps) {
  return (
    <div className="setting">
      <div className="setting-label">{htmlFor ? <label htmlFor={htmlFor}>{label}</label> : <span>{label}</span>}</div>
      <div className="setting-control">
        {children}
        {hint && (
          <p id={hintId} className="setting-hint">
            {hint}
          </p>
        )}
      </div>
    </div>
  );
}

interface ToggleProps {
  label: string;
  hint?: ReactNode;
  checked: boolean;
  patch: (value: boolean) => SettingsPatch;
}

/** Saves as soon as it is switched. */
export function ToggleSetting({ label, hint, checked, patch }: ToggleProps) {
  const save = useSaveSetting();
  const id = useId();
  const [pending, setPending] = useState<boolean | null>(null);
  const shown = save.isPending && pending !== null ? pending : checked;
  return (
    <div className="setting setting--toggle">
      <div className="setting-control">
        <label className="toggle" htmlFor={id}>
          <input
            id={id}
            type="checkbox"
            checked={shown}
            aria-describedby={hint ? `${id}-hint` : undefined}
            onChange={(event) => {
              setPending(event.target.checked);
              save.mutate(patch(event.target.checked));
            }}
          />
          <span>{label}</span>
        </label>
        {hint && (
          <p id={`${id}-hint`} className="setting-hint">
            {hint}
          </p>
        )}
        <FieldError id={`${id}-error`} error={save.error} />
      </div>
    </div>
  );
}

interface SelectProps {
  label: string;
  hint?: ReactNode;
  value: string;
  options: readonly Option[];
  patch: (value: string) => SettingsPatch;
}

/** Saves as soon as a choice is made. A value the UI doesn't know is still shown. */
export function SelectSetting({ label, hint, value, options, patch }: SelectProps) {
  const save = useSaveSetting();
  const id = useId();
  const [pending, setPending] = useState<string | null>(null);
  const shown = save.isPending && pending !== null ? pending : value;
  const known = options.some((option) => option.value === shown);
  return (
    <SettingRow label={label} htmlFor={id} hint={hint} hintId={`${id}-hint`}>
      <select
        id={id}
        className="field"
        value={shown}
        aria-describedby={hint ? `${id}-hint` : undefined}
        onChange={(event) => {
          setPending(event.target.value);
          save.mutate(patch(event.target.value));
        }}
      >
        {!known && <option value={shown}>{shown}</option>}
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
      <FieldError id={`${id}-error`} error={save.error} />
    </SettingRow>
  );
}

/**
 * Local typing state for a text setting: refetches never overwrite what the user is
 * typing, and a refused value stays in the field so it can be fixed. After a save the
 * field keeps the typed text until the app's new value arrives, so the old value never
 * flashes back in between.
 */
function useDraft(value: string) {
  const [draft, setDraft] = useState(value);
  const [editing, setEditing] = useState(false);
  // The value shown when a save succeeded; the field waits until `value` moves on.
  const [savedOver, setSavedOver] = useState<string | null>(null);
  useEffect(() => {
    if (editing || (savedOver !== null && value === savedOver)) return;
    setSavedOver(null);
    setDraft(value);
  }, [value, editing, savedOver]);
  return {
    draft,
    edit: (text: string) => {
      setEditing(true);
      setDraft(text);
    },
    settle: () => {
      setSavedOver(value);
      setEditing(false);
    },
    revert: () => {
      setSavedOver(null);
      setEditing(false);
      setDraft(value);
    },
  };
}

interface TextProps {
  label: string;
  hint?: ReactNode;
  value: string;
  placeholder?: string;
  /** Turns the typed text into the PATCH; return a string to refuse it with that sentence. */
  patch: (value: string) => SettingsPatch | string;
  inputMode?: "text" | "decimal";
  mono?: boolean;
  /** A short value (a rate) rather than a path or id. */
  narrow?: boolean;
  /** Extra controls after the field (the folder chooser); their commits count as explicit. */
  after?: (commit: (value: string) => void, busy: boolean) => ReactNode;
  /** A problem from outside the field (the folder chooser failing). */
  extraError?: string | null;
}

/** Saves on Enter or when focus leaves; Escape puts the saved value back. */
export function TextSetting({
  label,
  hint,
  value,
  placeholder,
  patch,
  inputMode,
  mono,
  narrow,
  after,
  extraError,
}: TextProps) {
  const save = useSaveSetting();
  const id = useId();
  const draft = useDraft(value);
  const [refusal, setRefusal] = useState<string | null>(null);
  // The last text sent and not yet saved. Leaving the field never resends it (Enter
  // then blur, or a refused value); Enter or the chooser does, once nothing is pending,
  // so a refused folder can be retried after it has been created.
  const [sent, setSent] = useState<string | null>(null);
  const error = refusal ?? save.error ?? extraError;

  const commit = (text: string, explicit = false) => {
    if (text === sent && (save.isPending || !explicit)) return;
    draft.edit(text);
    if (text === value) {
      setRefusal(null);
      save.reset();
      draft.settle();
      return;
    }
    const change = patch(text);
    if (typeof change === "string") {
      setRefusal(change);
      return;
    }
    setRefusal(null);
    setSent(text);
    save.mutate(change, {
      onSuccess: () => {
        setSent(null);
        draft.settle();
      },
    });
  };

  const describedBy = [hint ? `${id}-hint` : null, error ? `${id}-error` : null].filter(Boolean).join(" ");
  return (
    <SettingRow label={label} htmlFor={id} hint={hint} hintId={`${id}-hint`}>
      <div className="field-line">
        <input
          id={id}
          className={["field", narrow ? "field--narrow" : "field--wide", mono ? "mono" : ""].join(" ").trim()}
          type="text"
          value={draft.draft}
          placeholder={placeholder}
          inputMode={inputMode}
          spellCheck={false}
          autoComplete="off"
          aria-invalid={error ? true : undefined}
          aria-describedby={describedBy || undefined}
          onChange={(event) => {
            setSent(null);
            draft.edit(event.target.value);
          }}
          onBlur={() => commit(draft.draft)}
          onKeyDown={(event) => {
            if (event.key === "Enter") commit(draft.draft, true);
            if (event.key === "Escape") {
              setSent(null);
              draft.revert();
              setRefusal(null);
              save.reset();
            }
          }}
        />
        {after?.((text) => commit(text, true), save.isPending)}
      </div>
      <FieldError id={`${id}-error`} error={error} />
    </SettingRow>
  );
}

interface NumberProps {
  label: string;
  hint?: ReactNode;
  value: number;
  example: string;
  patch: (value: number) => SettingsPatch;
}

/** A dollar rate: refused here when it isn't a number, by the app when it is out of range. */
export function NumberSetting({ label, hint, value, example, patch }: NumberProps) {
  return (
    <TextSetting
      label={label}
      hint={hint}
      value={String(value)}
      inputMode="decimal"
      mono
      narrow
      patch={(text) => {
        const number = Number(text.trim());
        if (text.trim() === "" || !Number.isFinite(number)) return `Enter a number of dollars, like ${example}.`;
        return patch(number);
      }}
    />
  );
}
