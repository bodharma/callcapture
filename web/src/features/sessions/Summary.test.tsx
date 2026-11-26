import { render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it } from "vitest";
import type { AnalysisDTO, SpeakerDTO } from "../../api/types";
import { analysisFixture } from "../../test/fixtures";
import { PlayerProvider } from "./player";
import { Summary } from "./Summary";

const speakers: SpeakerDTO[] = [
  { label: "Speaker 1", name: "Olena", renamed: true },
  { label: "Speaker 2", name: "Speaker 2", renamed: false },
];

function renderSummary(analysis: AnalysisDTO, list: SpeakerDTO[] = speakers) {
  return render(
    <MemoryRouter>
      <PlayerProvider>
        <Summary status="transcribed" analysis={analysis} note={null} markers={[]} speakers={list} />
      </PlayerProvider>
    </MemoryRouter>,
  );
}

const rich: AnalysisDTO = {
  ...analysisFixture,
  sentiment: {
    overall: "positive",
    overallScore: 0.42,
    bySpeaker: {},
    arc: [
      { t: 0, score: -0.2 },
      { t: 600, score: 0.1 },
      { t: 1200, score: 0.5 },
    ],
  },
  speakers: [
    { ...analysisFixture.speakers[0], dominantEmotion: "calm", valence: 0.34 },
    { ...analysisFixture.speakers[1], dominantEmotion: "tense", valence: -0.27 },
  ],
  insights: {
    ...analysisFixture.insights!,
    recommendedActions: ["Book the migration window today.", "<b>Share</b> the rollback plan."],
  },
};

describe("Summary insights", () => {
  it("shows the overall tone, its arc, each speaker's emotion and the recommended actions", () => {
    renderSummary(rich);
    expect(screen.getByText("Overall: positive (+0.42)")).toBeTruthy();
    expect(screen.getByRole("img", { name: "Tone over the call, from -0.20 to +0.50" })).toBeTruthy();
    const who = screen.getByRole("complementary", { name: "Who spoke" });
    expect(within(who).getByText("calm +0.3")).toBeTruthy();
    expect(within(who).getByText("tense -0.3")).toBeTruthy();
    const actions = screen.getByRole("region", { name: "Recommended actions" });
    expect(within(actions).getAllByRole("listitem").map((li) => li.textContent)).toEqual([
      "Book the migration window today.",
      "<b>Share</b> the rollback plan.",
    ]);
    expect(within(actions).queryByRole("checkbox")).toBeNull();
    // Recommended actions sit right after To do.
    const todo = screen.getByRole("region", { name: "To do" });
    expect(todo.nextElementSibling).toBe(actions);
  });

  it("renders nothing for absent sentiment, emotions or recommended actions", () => {
    renderSummary(analysisFixture);
    expect(screen.queryByText(/^Overall:/)).toBeNull();
    expect(screen.queryByRole("img", { name: /Tone over the call/ })).toBeNull();
    expect(screen.queryByRole("region", { name: "Recommended actions" })).toBeNull();
    const who = screen.getByRole("complementary", { name: "Who spoke" });
    expect(who.querySelector(".who-tone")).toBeNull();
  });

  it("shows the overall tone without an arc when the arc has one point", () => {
    renderSummary({ ...rich, sentiment: { ...rich.sentiment!, arc: [{ t: 0, score: 0.4 }] } });
    expect(screen.getByText("Overall: positive (+0.42)")).toBeTruthy();
    expect(screen.queryByRole("img", { name: /Tone over the call/ })).toBeNull();
  });

  it("never offers to name the self speaker", () => {
    const withSelf: AnalysisDTO = {
      ...analysisFixture,
      speakers: [{ ...analysisFixture.speakers[0], label: "You", name: "You", isSelf: true }, analysisFixture.speakers[1]],
    };
    const list: SpeakerDTO[] = [
      { label: "You", name: "You", renamed: false },
      { label: "Speaker 2", name: "Speaker 2", renamed: false },
    ];
    const { unmount } = renderSummary(withSelf, list);
    expect(screen.getByRole("link", { name: "Name Speaker 2" })).toBeTruthy();
    expect(screen.queryByRole("link", { name: "Name You" })).toBeNull();
    unmount();
    renderSummary(withSelf, [list[0]]);
    expect(screen.queryByRole("link", { name: /^Name / })).toBeNull();
  });
});
