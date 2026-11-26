import { useEffect, useRef, useState } from "react";
import WaveSurfer from "wavesurfer.js";
import type { MarkerKind, TapeMarker } from "../../api/types";
import { timecode } from "../../lib/format";
import { usePlaybackTime, usePlayer } from "./player";
import "./Tape.css";

export interface TapeProps {
  /** Same-origin ranged audio URL; the browser streams it. */
  src: string;
  /** Session length in seconds; falls back to the audio's own duration. */
  duration?: number;
  /** Precomputed peaks (0…1) from the server; empty draws no wave. */
  peaks: number[];
  markers: TapeMarker[];
  /** True while the app records: playback would be captured, so it is off. */
  recording: boolean;
}

const RATES = [0.75, 1, 1.25, 1.5, 2] as const;

const KIND_LABEL: Record<MarkerKind, string> = {
  decision: "Decision",
  question: "Question",
  note: "Your note",
};

const LEGEND: { kind: MarkerKind; label: string }[] = [
  { kind: "decision", label: "decision" },
  { kind: "question", label: "open question" },
  { kind: "note", label: "your note" },
];

/** Canvas colours for wavesurfer, read from the design tokens. */
function token(name: string, fallback: string): string {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value || fallback;
}

export function Tape({ src, duration, peaks, markers, recording }: TapeProps) {
  const player = usePlayer();
  const time = usePlaybackTime();
  const audioRef = useRef<HTMLAudioElement>(null);
  const waveRef = useRef<HTMLDivElement>(null);
  const [playing, setPlaying] = useState(false);
  const [rate, setRate] = useState(1);
  const [mediaDuration, setMediaDuration] = useState(0);
  const [loadError, setLoadError] = useState(false);
  const known = duration !== undefined && duration > 0 ? duration : undefined;
  const total = known ?? mediaDuration;

  useEffect(() => {
    player.attach(audioRef.current);
    return () => player.attach(null);
  }, [player]);

  useEffect(() => {
    player.setBlocked(recording);
  }, [player, recording]);

  useEffect(() => {
    const container = waveRef.current;
    const media = audioRef.current;
    if (!container || !media || peaks.length === 0) return;
    const wave = WaveSurfer.create({
      container,
      media,
      peaks: [peaks],
      duration: known,
      height: 48,
      waveColor: token("--ash", "#93a08f"),
      progressColor: token("--fg", "#dfe8da"),
      cursorColor: token("--rust", "#e0805f"),
      cursorWidth: 2,
      barWidth: 3,
      barGap: 2,
      barRadius: 1,
      normalize: false,
      dragToSeek: true,
    });
    return () => wave.destroy();
  }, [peaks, known]);

  const togglePlay = () => {
    const media = audioRef.current;
    if (!media || recording) return;
    if (!media.paused) {
      media.pause();
      return;
    }
    media.play().catch((error: unknown) => {
      // An interrupted play() (a quick pause) is not a failure; an unplayable source is.
      if (error instanceof DOMException && error.name === "NotSupportedError") setLoadError(true);
    });
  };

  const changeRate = (value: number) => {
    setRate(value);
    if (audioRef.current) audioRef.current.playbackRate = value;
  };

  return (
    <section className="tape" aria-label="Playback">
      <audio
        ref={audioRef}
        src={src}
        preload="metadata"
        onPlay={(event) => {
          if (player.isBlocked()) event.currentTarget.pause();
          else setPlaying(true);
        }}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onLoadedMetadata={(event) => setMediaDuration(event.currentTarget.duration || 0)}
        onError={() => setLoadError(true)}
      />
      <div className="tape-frame">
        <div className="tape-inner">
          <div ref={waveRef} className="tape-wave" />
          {total > 0 &&
            markers.map((marker) => (
              <button
                key={marker.id}
                type="button"
                className={`tape-marker tape-marker--${marker.kind}`}
                style={{ left: `${Math.min(100, Math.max(0, (marker.time / total) * 100))}%` }}
                aria-label={`${KIND_LABEL[marker.kind]} at ${timecode(marker.time)}: ${marker.text}`}
                title={`${KIND_LABEL[marker.kind]} at ${timecode(marker.time)}: ${marker.text}`}
                onClick={() => player.seek(marker.time, { play: true })}
              />
            ))}
        </div>
      </div>
      <div className="tape-controls">
        <button
          type="button"
          className="tape-play"
          aria-label={playing ? "Pause" : "Play"}
          disabled={recording}
          onClick={togglePlay}
        >
          <svg width="11" height="11" viewBox="0 0 24 24" aria-hidden="true">
            {playing ? <path d="M6 4h4v16H6zM14 4h4v16h-4z" /> : <path d="M7 4v16l13-8z" />}
          </svg>
        </button>
        <span className="tape-time">
          {timecode(time)} / {timecode(total)}
        </span>
        {markers.length > 0 && (
          <span className="tape-legend">
            {LEGEND.map(({ kind, label }) => (
              <span key={kind} className="tape-legend-item">
                <span className={`tape-glyph tape-glyph--${kind}`} aria-hidden="true" />
                {label}
              </span>
            ))}
          </span>
        )}
        <span className="tape-speed" role="group" aria-label="Playback speed">
          {RATES.map((value) => (
            <button
              key={value}
              type="button"
              aria-pressed={rate === value}
              onClick={() => changeRate(value)}
            >
              {value}×
            </button>
          ))}
        </span>
      </div>
      {recording && (
        <p className="tape-note">
          <span>Playback is off while recording</span>
          <span className="tape-note-why">, so it isn't captured into the new recording.</span>
        </p>
      )}
      {loadError && (
        <p className="notice notice--warn">
          The audio couldn't be played. Check that the recording file is still there, then reload
          the page.
        </p>
      )}
    </section>
  );
}
