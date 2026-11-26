import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { TapeMarker } from "../../api/types";
import { PlayerProvider } from "./player";
import { Tape } from "./Tape";

const { create, destroy } = vi.hoisted(() => {
  const destroy = vi.fn();
  const create = vi.fn(() => ({ destroy, on: vi.fn(() => () => {}) }));
  return { create, destroy };
});
vi.mock("wavesurfer.js", () => ({ default: { create } }));

const markers: TapeMarker[] = [
  { id: "m1", time: 50, kind: "decision", text: "Ship Friday" },
  { id: "m2", time: 150, kind: "question", text: "Who owns rollback?" },
];

function renderTape(recording: boolean) {
  const ui = (rec: boolean) => (
    <PlayerProvider>
      <Tape
        src="/api/sessions/S1/audio"
        duration={200}
        peaks={[0.1, 0.5, 0.2]}
        markers={markers}
        recording={rec}
      />
    </PlayerProvider>
  );
  const view = render(ui(recording));
  const audio = view.container.querySelector("audio") as HTMLAudioElement;
  return { ...view, audio, setRecording: (rec: boolean) => view.rerender(ui(rec)) };
}

beforeEach(() => {
  create.mockClear();
  destroy.mockClear();
});

describe("Tape", () => {
  it("places each marker at time / duration as a percentage", () => {
    renderTape(false);
    const decision = screen.getByRole("button", { name: "Decision at 00:50: Ship Friday" });
    const question = screen.getByRole("button", { name: "Question at 02:30: Who owns rollback?" });
    expect(decision.style.left).toBe("25%");
    expect(question.style.left).toBe("75%");
  });

  it("feeds wavesurfer the precomputed peaks and the ranged audio element", () => {
    const { audio } = renderTape(false);
    expect(audio.getAttribute("src")).toBe("/api/sessions/S1/audio");
    expect(audio.controls).toBe(false);
    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({ media: audio, peaks: [[0.1, 0.5, 0.2]], duration: 200 }),
    );
    expect(create.mock.calls[0]).not.toHaveProperty("0.url");
  });

  it("disables playback with a caption while recording", () => {
    renderTape(true);
    expect((screen.getByRole("button", { name: "Play" }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText("Playback is off while recording")).toBeTruthy();
  });

  it("pauses playback when a recording starts", () => {
    const { audio, setRecording } = renderTape(false);
    fireEvent.click(screen.getByRole("button", { name: "Play" }));
    expect(audio.play).toHaveBeenCalled();
    setRecording(true);
    expect(audio.pause).toHaveBeenCalled();
    expect(audio.paused).toBe(true);
  });

  it("changes the playback speed", () => {
    const { audio } = renderTape(false);
    const fast = screen.getByRole("button", { name: "1.5×" });
    fireEvent.click(fast);
    expect(audio.playbackRate).toBe(1.5);
    expect(fast.getAttribute("aria-pressed")).toBe("true");
  });

  it("seeks to a marker when it is clicked", () => {
    const { audio } = renderTape(false);
    fireEvent.click(screen.getByRole("button", { name: "Question at 02:30: Who owns rollback?" }));
    expect(audio.currentTime).toBe(150);
  });

  it("shows a legend for the marker kinds", () => {
    renderTape(false);
    expect(screen.getByText("decision")).toBeTruthy();
    expect(screen.getByText("open question")).toBeTruthy();
    expect(screen.getByText("your note")).toBeTruthy();
  });
});
