import { Link } from "react-router";
import { PaneHeader, Section } from "../controls";
import type { SettingsDTO } from "../types";
import type { PaneProps } from "./paneProps";

const PROVIDER_NAMES: Record<string, string> = {
  auto: "AssemblyAI or Deepgram (by language)",
  assemblyai: "AssemblyAI",
  deepgram: "Deepgram",
  groq: "Groq",
  openai: "OpenAI",
};

function isThisMac(address: string): boolean {
  try {
    const host = new URL(address).hostname;
    return host === "localhost" || host === "127.0.0.1" || host === "[::1]";
  } catch {
    return false;
  }
}

function transcriptionLine(settings: SettingsDTO): string {
  if (settings.transcription.engine === "local_whisper") return "Audio is transcribed on this Mac.";
  const provider = PROVIDER_NAMES[settings.transcription.remoteProvider] ?? settings.transcription.remoteProvider;
  return `Recordings are sent to ${provider} to be transcribed.`;
}

function notesLine(settings: SettingsDTO): string {
  if (settings.aiNotes.provider === "openrouter") {
    return "Transcripts are sent to OpenRouter to write final notes, and live notes when you turn them on for a meeting.";
  }
  return isThisMac(settings.aiNotes.localBaseURL)
    ? "Notes are written by the local model on this Mac."
    : `Notes are written by the model server at ${settings.aiNotes.localBaseURL}.`;
}

/** What leaves this Mac with the current settings. It reports; the controls live in the other panes. */
export function PrivacyPane({ settings }: PaneProps) {
  return (
    <>
      <PaneHeader title="Privacy" lead="What leaves this Mac with your current settings." />
      <Section title="With these settings">
        <ul className="privacy-list">
          <li>
            {transcriptionLine(settings)} <Link to="/settings/transcription">Change in Transcription</Link>
          </li>
          <li>
            {notesLine(settings)} <Link to="/settings/ai-notes">Change in AI notes</Link>
          </li>
          <li>Speaker and emotion models run on this Mac once they are downloaded.</li>
        </ul>
      </Section>
      <Section title="Always">
        <ul className="privacy-list">
          <li>API keys are kept in the macOS Keychain. This page can save or remove them, but never shows them.</li>
          <li>
            This page is served by CallCapture on this Mac only (127.0.0.1). Other devices and other websites can't
            open it.
          </li>
        </ul>
      </Section>
    </>
  );
}
