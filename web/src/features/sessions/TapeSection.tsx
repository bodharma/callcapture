import type { SessionDTO, TapeMarker } from "../../api/types";
import { sessionPath, useSessionPart } from "./api";
import { Tape } from "./Tape";

interface TapeSectionProps {
  session: SessionDTO;
  markers: TapeMarker[];
  recording: boolean;
}

/** Loads the peaks and shows the tape, or says why there is nothing to play. */
export function TapeSection({ session, markers, recording }: TapeSectionProps) {
  const playable = session.hasAudio && session.status !== "recording";
  const peaks = useSessionPart(session.id, "peaks", playable);

  if (session.status === "recording") {
    return <p className="empty">Still recording. The tape shows up here after you stop.</p>;
  }
  if (!session.hasAudio) {
    return <p className="empty">The audio file is missing, so there is nothing to play.</p>;
  }
  if (peaks.isPending) return <div className="tape-frame tape-frame--loading" aria-busy="true" />;

  return (
    <>
      <Tape
        src={`${sessionPath(session.id)}/audio`}
        duration={session.durationSec}
        peaks={peaks.data ?? []}
        markers={markers}
        recording={recording}
      />
      {peaks.isError && (
        <p className="notice notice--warn">The waveform couldn't be drawn. Playback still works.</p>
      )}
    </>
  );
}
