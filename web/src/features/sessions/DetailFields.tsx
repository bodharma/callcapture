import { useId } from "react";
import { errorText } from "../../api/client";
import type { SessionDetailsPatch, SessionDTO, SessionOption } from "../../api/types";
import { costSplit, languageName, length, recordedAt } from "../../lib/format";
import { useSessionOptions, useUpdateDetails } from "./api";

type EditableField = keyof SessionDetailsPatch;

const NAMES: Record<EditableField, string> = {
  recordingType: "type",
  language: "speech language",
  notesLanguage: "notes language",
};

/** The header's field row: type and languages are editable, the rest is read-only. */
export function DetailFields({ session }: { session: SessionDTO }) {
  const options = useSessionOptions().data;
  const fields: [string, string][] = [["Recorded", recordedAt(new Date(session.startedAt))]];
  if (session.durationSec !== undefined) fields.push(["Length", length(session.durationSec)]);
  if (session.sourceApp) fields.push(["Source", session.sourceApp]);
  const cost = costSplit(session.costs);

  return (
    <dl className="fields">
      {fields.map(([term, value]) => (
        <ReadOnly key={term} term={term} value={value} />
      ))}
      <Editable session={session} field="recordingType" label="Type" choices={options?.recordingTypes} />
      <Editable session={session} field="language" label="Speech" choices={options?.languages} />
      <Editable session={session} field="notesLanguage" label="Notes" choices={options?.languages} />
      {cost !== undefined && <ReadOnly term="Cost" value={cost} />}
    </dl>
  );
}

function ReadOnly({ term, value }: { term: string; value: string }) {
  return (
    <div>
      <dt>{term}</dt>
      <dd>{value}</dd>
    </div>
  );
}

interface EditableProps {
  session: SessionDTO;
  field: EditableField;
  label: string;
  choices: SessionOption[] | undefined;
}

/**
 * A native select that saves on change. While the save runs it shows the chosen
 * value; if it fails the field goes back to the server's value and a sentence says why.
 */
function Editable({ session, field, label, choices }: EditableProps) {
  const id = useId();
  const save = useUpdateDetails(session.id);
  const serverValue = session[field];
  const shown = save.isPending && save.variables?.[field] !== undefined ? save.variables[field] : serverValue;

  if (!choices) {
    // Without the app's list there is nothing to choose from; show what is saved.
    return <ReadOnly term={label} value={field === "recordingType" ? serverValue : languageName(serverValue)} />;
  }
  const known = choices.some((choice) => choice.value === shown);
  const shownChoices = known ? choices : [...choices, { value: shown, label: shown }];

  return (
    <div className="field-edit">
      <dt>
        <label htmlFor={id}>{label}</label>
      </dt>
      <dd>
        <select
          id={id}
          className="field-select"
          value={shown}
          disabled={save.isPending}
          aria-invalid={save.isError || undefined}
          aria-describedby={save.isError ? `${id}-error` : undefined}
          onChange={(event) => save.mutate({ [field]: event.target.value })}
        >
          {shownChoices.map((choice) => (
            <option key={choice.value} value={choice.value}>
              {choice.label}
            </option>
          ))}
        </select>
        {save.isError && (
          <p id={`${id}-error`} className="field-note" role="alert">
            Couldn't change the {NAMES[field]}. {errorText(save.error)} Pick it again to retry.
          </p>
        )}
      </dd>
    </div>
  );
}

/** A thin bar under the field row while the session transcribes; it follows the app's progress. */
export function TranscribeProgress({ session }: { session: SessionDTO }) {
  if (session.status !== "transcribing") return null;
  const value = session.progress;
  const percent = value === undefined ? undefined : Math.round(Math.min(Math.max(value, 0), 1) * 100);
  return (
    <div
      className="progress"
      role="progressbar"
      aria-label="Transcription progress"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={percent}
      aria-valuetext={percent === undefined ? "Working" : `${percent}%`}
    >
      <div className="progress-fill" style={{ width: `${percent ?? 0}%` }} />
    </div>
  );
}
