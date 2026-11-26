import { createContext, useContext, useMemo, useRef, useState, type ReactNode } from "react";

/**
 * One audio element per session page, shared by the tape (which owns it) and
 * by anything that seeks: transcript lines, summary timecodes, search hits.
 */
export interface PlayerApi {
  /** The tape registers its `<audio>` element here (null on unmount). */
  attach(element: HTMLAudioElement | null): void;
  /** Moves the playhead; plays from there when asked and playback is allowed. */
  seek(time: number, options?: { play?: boolean }): void;
  /** While blocked (recording), playback is paused and seeks never start it. */
  setBlocked(blocked: boolean): void;
  isBlocked(): boolean;
}

const PlayerContext = createContext<PlayerApi | null>(null);
const TimeContext = createContext(0);

export function PlayerProvider({ children }: { children: ReactNode }) {
  const audio = useRef<HTMLAudioElement | null>(null);
  const blocked = useRef(false);
  const pendingSeek = useRef<number | null>(null);
  const [time, setTime] = useState(0);

  const api = useMemo<PlayerApi>(() => {
    const onTime = (event: Event) => setTime((event.target as HTMLAudioElement).currentTime);
    return {
      attach(element) {
        audio.current?.removeEventListener("timeupdate", onTime);
        audio.current?.removeEventListener("seeked", onTime);
        audio.current = element;
        if (!element) return;
        element.addEventListener("timeupdate", onTime);
        element.addEventListener("seeked", onTime);
        if (pendingSeek.current !== null) {
          element.currentTime = pendingSeek.current;
          setTime(pendingSeek.current);
          pendingSeek.current = null;
        }
      },
      seek(target, options) {
        const element = audio.current;
        const at = Math.max(0, target);
        setTime(at);
        if (!element) {
          pendingSeek.current = at;
          return;
        }
        element.currentTime = at;
        if (options?.play && !blocked.current) {
          element.play().catch(() => {
            // Refused by the browser (autoplay policy) or a load error; the tape shows load errors.
          });
        }
      },
      setBlocked(value) {
        blocked.current = value;
        if (value && audio.current && !audio.current.paused) audio.current.pause();
      },
      isBlocked: () => blocked.current,
    };
  }, []);

  return (
    <PlayerContext.Provider value={api}>
      <TimeContext.Provider value={time}>{children}</TimeContext.Provider>
    </PlayerContext.Provider>
  );
}

export function usePlayer(): PlayerApi {
  const player = useContext(PlayerContext);
  if (!player) throw new Error("usePlayer needs a PlayerProvider");
  return player;
}

/** The playhead in seconds; re-renders on every timeupdate (about 4 times a second). */
export function usePlaybackTime(): number {
  return useContext(TimeContext);
}
