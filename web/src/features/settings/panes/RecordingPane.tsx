import { PaneHeader, ToggleSetting } from "../controls";
import { FolderSetting } from "../FolderSetting";
import type { PaneProps } from "./paneProps";

export function RecordingPane({ settings }: PaneProps) {
  return (
    <>
      <PaneHeader title="Recording" lead="Where recordings are kept and what is saved with them." />
      <FolderSetting
        label="Output folder"
        setting="outputDirectory"
        value={settings.recording.outputDirectory}
        chooseLabel="Choose output folder"
        hint="Recordings, transcripts and notes are saved here."
        patch={(outputDirectory) => ({ recording: { outputDirectory } })}
      />
      <ToggleSetting
        label="Keep a separate microphone track"
        checked={settings.recording.keepSeparateMicTrack}
        hint="Not used yet: with the microphone on, CallCapture already saves separate microphone and system tracks next to each recording."
        patch={(keepSeparateMicTrack) => ({ recording: { keepSeparateMicTrack } })}
      />
    </>
  );
}
