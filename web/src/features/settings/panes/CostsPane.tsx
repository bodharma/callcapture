import { useResetCosts } from "../api";
import { FieldError, NumberSetting, PaneHeader, SettingRow } from "../controls";
import type { SettingsDTO } from "../types";
import type { PaneProps } from "./paneProps";

type Rate = keyof SettingsDTO["costs"];

const RATES: readonly { key: Rate; label: string; example: string }[] = [
  { key: "assemblyAIPerMin", label: "AssemblyAI, per minute", example: "0.0035" },
  { key: "deepgramPerMin", label: "Deepgram, per minute", example: "0.0043" },
  { key: "openAIPerMin", label: "OpenAI Whisper, per minute", example: "0.006" },
  { key: "groqPerMin", label: "Groq, per minute", example: "0.0007" },
];

export function CostsPane({ settings }: PaneProps) {
  const reset = useResetCosts();
  return (
    <>
      <PaneHeader
        title="Costs"
        lead="The US dollar rates used to work out what each recording cost. Each session shows its own total."
      />
      {RATES.map((rate) => (
        <NumberSetting
          key={rate.key}
          label={rate.label}
          value={settings.costs[rate.key]}
          example={rate.example}
          patch={(value) => ({ costs: { [rate.key]: value } })}
        />
      ))}
      <SettingRow label="Local Whisper">
        <p className="pane-text mono">free</p>
      </SettingRow>
      <NumberSetting
        label="AI notes fallback, per million tokens"
        value={settings.costs.llmFallbackPer1M}
        example="3.00"
        hint="OpenRouter reports what AI notes actually cost; this rate is used only when it can't."
        patch={(llmFallbackPer1M) => ({ costs: { llmFallbackPer1M } })}
      />
      <div className="pane-actions">
        <button type="button" className="btn" disabled={reset.isPending} onClick={() => reset.mutate()}>
          Reset to defaults
        </button>
        <FieldError id="costs-reset-error" error={reset.error} />
      </div>
    </>
  );
}
