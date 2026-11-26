import { useEffect, useId, useRef, useState } from "react";
import { errorText } from "../../../api/client";
import { useCatalog, useRefreshCatalog, useTestKey } from "../api";
import { OfflineReason, PaneHeader, Section, SelectSetting, TextSetting } from "../controls";
import { ModelTable } from "../ModelTable";
import { perHour } from "../modelSort";
import { SecretSetting } from "../SecretSetting";
import type { CatalogDTO, SettingsDTO } from "../types";
import type { PaneProps } from "./paneProps";

const PROVIDERS = [
  { value: "openrouter", label: "OpenRouter (cloud)" },
  { value: "local", label: "Local (Ollama)" },
] as const;

/** Where notes are written, and which model writes them for each job. */
export function AINotesPane({ settings, online }: PaneProps) {
  const { aiNotes } = settings;
  return (
    <>
      <PaneHeader
        title="AI notes"
        lead="Live notes run for the whole meeting, final notes once at the end. Pick a model for each."
      />
      <SelectSetting
        label="Where notes are written"
        value={aiNotes.provider}
        options={PROVIDERS}
        patch={(provider) => ({ aiNotes: { provider } })}
      />
      {aiNotes.provider === "openrouter" ? (
        <OpenRouterNotes settings={settings} online={online} />
      ) : (
        <LocalNotes settings={settings} />
      )}
    </>
  );
}

function OpenRouterNotes({ settings, online }: PaneProps) {
  const catalog = useCatalog();
  // A new or removed key makes an earlier test result stale: remount the test.
  const [keyVersion, setKeyVersion] = useState(0);
  useRefreshWhenStale(online);
  return (
    <>
      <SecretSetting
        label="OpenRouter key"
        name="openrouter"
        set={settings.secrets.openrouter.set}
        hint="Used for AI notes and the independent model scores."
        onChanged={() => setKeyVersion((version) => version + 1)}
      >
        <KeyTest
          key={keyVersion}
          set={settings.secrets.openrouter.set}
          online={online}
          reason={settings.offlineReasons.testKey}
        />
      </SecretSetting>
      <Section title="Models">
        <div className="model-cards">
          <ModelCard role="live" settings={settings} catalog={catalog.data} />
          <ModelCard role="final" settings={settings} catalog={catalog.data} />
        </div>
        {catalog.isError && !catalog.data && (
          <p className="field-error" role="alert">
            The model list didn't load. {errorText(catalog.error)}
          </p>
        )}
        {catalog.data && (
          <ModelTable
            catalog={catalog.data}
            liveModel={settings.aiNotes.liveModel}
            finalModel={settings.aiNotes.finalModel}
            online={online}
            offlineReason={settings.offlineReasons.refreshCatalog}
          />
        )}
      </Section>
    </>
  );
}

/** Like opening the app's settings: refresh once when online, within the app's daily cache. */
function useRefreshWhenStale(online: boolean | undefined) {
  const refresh = useRefreshCatalog();
  const done = useRef(false);
  useEffect(() => {
    if (online !== true || done.current) return;
    done.current = true;
    refresh.mutate(false);
  }, [online, refresh]);
}

function KeyTest({ set, online, reason }: { set: boolean; online: boolean | undefined; reason: string }) {
  const test = useTestKey();
  const offline = online === false;
  return (
    <div className="key-test">
      <button
        type="button"
        className="btn btn--small"
        disabled={!set || offline || test.isPending}
        onClick={() => test.mutate()}
      >
        {test.isPending ? "Testing…" : "Test connection"}
      </button>
      {offline && <OfflineReason reason={reason} />}
      {test.isSuccess && (
        <p className={test.data.ok ? "notice notice--ok" : "notice notice--warn"} role="status">
          {test.data.message}
        </p>
      )}
      {test.isError && (
        <p className="field-error" role="alert">
          The test didn't run. {errorText(test.error)}
        </p>
      )}
    </div>
  );
}

interface CardProps {
  role: "live" | "final";
  settings: SettingsDTO;
  catalog: CatalogDTO | undefined;
}

/** The chosen model for one job, with its estimated cost per meeting hour. */
function ModelCard({ role, settings, catalog }: CardProps) {
  const id = useId();
  const chosen = role === "live" ? settings.aiNotes.liveModel : settings.aiNotes.finalModel;
  const model = catalog?.models.find((m) => m.id === chosen);
  const warning = settings.aiNotes.warnings[role];
  const title = role === "live" ? "Live notes" : "Final notes";
  return (
    <div className="model-card" role="group" aria-labelledby={id}>
      <div className="model-card-main">
        <span className="model-card-role" id={id}>
          {title}
        </span>
        <span className="model-card-name" title={chosen}>
          {model?.name ?? (chosen || "Not chosen")}
        </span>
        {warning && <p className="notice notice--warn">{warning}</p>}
      </div>
      {model && (
        <span className="model-card-cost">
          <span className="mono">{perHour(model.hourlyUSD[role])}</span>
          <span>per meeting hour</span>
        </span>
      )}
    </div>
  );
}

function LocalNotes({ settings }: { settings: SettingsDTO }) {
  return (
    <>
      <TextSetting
        label="Local model"
        value={settings.aiNotes.localModel}
        placeholder="qwen2.5:32b"
        mono
        hint="Run a model in Ollama, for example ollama run qwen2.5:32b, then enter its id here."
        patch={(localModel) => ({ aiNotes: { localModel } })}
      />
      <TextSetting
        label="Local model server"
        value={settings.aiNotes.localBaseURL}
        mono
        hint="Ollama's address. The default is http://localhost:11434/v1."
        patch={(localBaseURL) => ({ aiNotes: { localBaseURL } })}
      />
    </>
  );
}
