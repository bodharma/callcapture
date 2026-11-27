import { PaneHeader, Section, SelectSetting } from "../controls";
import { ModelDownloadRow } from "../ModelDownloadRow";
import { SecretSetting } from "../SecretSetting";
import type { SettingsDTO } from "../types";
import type { PaneProps } from "./paneProps";

const ENGINES = [
  { value: "local_whisper", label: "Local Whisper, on this Mac" },
  { value: "remote", label: "Cloud service" },
] as const;

const WHISPER_MODELS = [
  { value: "base", label: "Base (fastest)" },
  { value: "small", label: "Small (balanced)" },
  { value: "medium", label: "Medium (most accurate)" },
] as const;

const PROVIDERS = [
  { value: "auto", label: "Auto by language (AssemblyAI and Deepgram)" },
  { value: "assemblyai", label: "AssemblyAI (speakers, sentiment, summaries, topics)" },
  { value: "deepgram", label: "Deepgram (speakers, sentiment, topics)" },
  { value: "groq", label: "Groq (fast Whisper)" },
  { value: "openai", label: "OpenAI Whisper" },
] as const;

export function TranscriptionPane({ settings, online }: PaneProps) {
  const { transcription } = settings;
  return (
    <>
      <PaneHeader title="Transcription" lead="Who turns the audio into text, and the models that separate speakers." />
      <SelectSetting
        label="Engine"
        value={transcription.engine}
        options={ENGINES}
        patch={(engine) => ({ transcription: { engine } })}
      />
      {transcription.engine === "local_whisper" && (
        <SelectSetting
          label="Whisper model"
          value={transcription.whisperModel}
          options={WHISPER_MODELS}
          patch={(whisperModel) => ({ transcription: { whisperModel } })}
        />
      )}
      {transcription.engine === "remote" && (
        <>
          <SelectSetting
            label="Provider"
            value={transcription.remoteProvider}
            options={PROVIDERS}
            patch={(remoteProvider) => ({ transcription: { remoteProvider } })}
          />
          <ProviderKeys settings={settings} />
        </>
      )}
      {transcription.engine !== "remote" && settings.aiNotes.provider === "local" && (
        // The app's wording, under the condition its API Keys section used.
        <p className="pane-text">No API keys required for current configuration.</p>
      )}
      <Section title="Speakers and emotion">
        <ModelDownloadRow
          label="Speaker models"
          kind="diarization"
          action="Download speaker models"
          state={transcription.models.diarization}
          online={online}
          offlineReason={settings.offlineReasons.download}
          hint="Needed to separate speakers in call and meeting recordings. Downloads once (tens of MB); recordings still get notes without them."
        />
        <ModelDownloadRow
          label="Emotion model"
          kind="emotion"
          action="Download emotion model"
          state={transcription.models.emotion}
          online={online}
          offlineReason={settings.offlineReasons.download}
          hint="Adds per-speaker emotion (valence and arousal) and an emotional arc. A large one-time download (about 1 GB); analysis still runs without it."
        />
      </Section>
    </>
  );
}

/** The keys the chosen cloud provider needs, as the app's settings show them. */
function ProviderKeys({ settings }: { settings: SettingsDTO }) {
  const { secrets } = settings;
  switch (settings.transcription.remoteProvider) {
    case "auto":
      return (
        <>
          <SecretSetting label="AssemblyAI key" name="assemblyai" set={secrets.assemblyai.set} />
          <SecretSetting
            label="Deepgram key"
            name="deepgram"
            set={secrets.deepgram.set}
            hint="Auto needs both keys. Each recording goes by its language: auto-detect, English, Spanish, French, German, Italian, Portuguese, Dutch, Japanese, Chinese, Korean and Hindi go to AssemblyAI; every other language, such as Ukrainian, Russian or Polish, goes to Deepgram."
          />
        </>
      );
    case "assemblyai":
      return (
        <SecretSetting
          label="AssemblyAI key"
          name="assemblyai"
          set={secrets.assemblyai.set}
          hint="Speakers, sentiment, summaries and topics for the languages AssemblyAI supports; text only for others."
        />
      );
    case "deepgram":
      return (
        <SecretSetting
          label="Deepgram key"
          name="deepgram"
          set={secrets.deepgram.set}
          hint="Nova-3 covers about 36 languages, with speakers and sentiment in one call."
        />
      );
    case "openai":
      return <SecretSetting label="OpenAI key" name="remote" set={secrets.remote.set} />;
    default:
      return <SecretSetting label="Groq key" name="remote" set={secrets.remote.set} />;
  }
}
