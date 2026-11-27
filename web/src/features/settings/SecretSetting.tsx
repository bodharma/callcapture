import { useId, useState, type FormEvent, type ReactNode } from "react";
import { useRemoveSecret, useSaveSecret } from "./api";
import { FieldError, SettingRow } from "./controls";
import type { SecretKey } from "./types";

interface SecretProps {
  label: string;
  name: SecretKey;
  set: boolean;
  hint?: ReactNode;
  /** Shown after the save controls (Test connection for OpenRouter). */
  children?: ReactNode;
  /** After a key is saved or removed, so results about the old key can be cleared. */
  onChanged?: () => void;
}

/**
 * A write-only key field: never prefilled, cleared after saving, and the app only
 * ever says whether a key is saved.
 */
export function SecretSetting({ label, name, set, hint, children, onChanged }: SecretProps) {
  const id = useId();
  const [value, setValue] = useState("");
  const [done, setDone] = useState<string | null>(null);
  const save = useSaveSecret(name);
  const remove = useRemoveSecret(name);
  const error = save.error ?? remove.error;

  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!value.trim()) return;
    remove.reset();
    setDone(null);
    save.mutate(value, {
      onSuccess: () => {
        setValue("");
        // Drop the key from the mutation's state (its variables), not only from the field.
        save.reset();
        setDone("Key saved.");
        onChanged?.();
      },
    });
  };

  return (
    <SettingRow label={label} htmlFor={id} hint={hint} hintId={`${id}-hint`}>
      <p className="secret-state">{set ? "Saved in the Keychain." : "Not set."}</p>
      <form className="field-line" onSubmit={submit}>
        <input
          id={id}
          className="field field--wide mono"
          type="password"
          autoComplete="new-password"
          spellCheck={false}
          value={value}
          placeholder={set ? "Paste a new key to replace it" : "Paste the key"}
          aria-describedby={hint ? `${id}-hint` : undefined}
          aria-invalid={error ? true : undefined}
          onChange={(event) => {
            setDone(null);
            setValue(event.target.value);
          }}
        />
        <button
          type="submit"
          className="btn btn--small"
          aria-label={`Save ${label}`}
          disabled={!value.trim() || save.isPending}
        >
          Save
        </button>
        {set && (
          <button
            type="button"
            className="btn btn--small btn--danger"
            aria-label={`Remove ${label}`}
            disabled={remove.isPending}
            onClick={() => {
              save.reset();
              setDone(null);
              remove.mutate(undefined, {
                onSuccess: () => {
                  setDone("Key removed.");
                  onChanged?.();
                },
              });
            }}
          >
            Remove
          </button>
        )}
      </form>
      {done && (
        <p className="notice notice--ok" role="status">
          {done}
        </p>
      )}
      <FieldError id={`${id}-error`} error={error} />
      {children}
    </SettingRow>
  );
}
