import { useSystemStatus } from "../api";
import { PaneHeader, Section, ToggleSetting } from "../controls";
import type { PaneProps } from "./paneProps";

export function GeneralPane({ settings }: PaneProps) {
  const system = useSystemStatus();
  return (
    <>
      <PaneHeader title="General" lead="What happens after a recording, and where per-meeting choices live." />
      <ToggleSetting
        label="Process recordings when they stop"
        checked={settings.general.autoProcessOnStop}
        hint="Transcribe and write notes as soon as a recording ends. When it's off, start processing from Sessions."
        patch={(autoProcessOnStop) => ({ general: { autoProcessOnStop } })}
      />
      <Section title="Each meeting">
        <p className="pane-text">
          Recording type, devices, languages and live notes are chosen for each meeting in the menu bar.
        </p>
      </Section>
      {system.data && (
        <Section title="About">
          <p className="pane-text">
            CallCapture <span className="mono">{system.data.version}</span>.{" "}
            {system.data.online ? "Online." : "Offline: recording, local transcription and saved notes still work."}
          </p>
        </Section>
      )}
    </>
  );
}
