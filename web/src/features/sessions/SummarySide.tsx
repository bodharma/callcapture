import { useId } from "react";
import { Link } from "react-router";
import type { AnalysisDTO, SpeakerDTO, SpeakerStats } from "../../api/types";
import { signed } from "../../lib/format";

type Sentiment = NonNullable<AnalysisDTO["sentiment"]>;

/**
 * The Summary's side column: the overall tone with its arc, then who spoke,
 * as the app's insights panel shows them. All analysis text is rendered as
 * plain React text (it comes from transcripts).
 */
export function SummarySide({ analysis, speakers }: { analysis: AnalysisDTO; speakers: SpeakerDTO[] }) {
  const { sentiment } = analysis;
  if (!sentiment && analysis.speakers.length === 0) return null;
  return (
    <div className="summary-side">
      {sentiment && <Tone sentiment={sentiment} />}
      {analysis.speakers.length > 0 && <WhoSpoke stats={analysis.speakers} speakers={speakers} />}
    </div>
  );
}

function Tone({ sentiment }: { sentiment: Sentiment }) {
  const id = useId();
  return (
    <section className="tone" aria-labelledby={id}>
      <h2 id={id} className="block-title">
        Tone
      </h2>
      <p className="tone-overall">
        Overall: {sentiment.overall} ({signed(sentiment.overallScore)})
      </p>
      {sentiment.arc.length > 1 && <Sparkline arc={sentiment.arc} />}
    </section>
  );
}

const ARC_W = 100;
const ARC_H = 28;

/** Valence over time: x spans the arc's time range, y maps -1…1 to bottom…top; dashed line is neutral. */
function Sparkline({ arc }: { arc: Sentiment["arc"] }) {
  const t0 = arc[0].t;
  const span = Math.max(arc[arc.length - 1].t - t0, 0.001);
  const points = arc
    .map(({ t, score }) => {
      const x = ((t - t0) / span) * ARC_W;
      const y = (1 - (Math.max(-1, Math.min(1, score)) + 1) / 2) * ARC_H;
      return `${x.toFixed(2)},${y.toFixed(2)}`;
    })
    .join(" ");
  const label = `Tone over the call, from ${signed(arc[0].score)} to ${signed(arc[arc.length - 1].score)}`;
  return (
    <svg className="tone-arc" viewBox={`0 0 ${ARC_W} ${ARC_H}`} preserveAspectRatio="none" role="img" aria-label={label}>
      <line className="tone-arc-mid" x1="0" y1={ARC_H / 2} x2={ARC_W} y2={ARC_H / 2} vectorEffect="non-scaling-stroke" />
      <polyline className="tone-arc-line" points={points} vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

const SEGMENTS = 25;

const isYou = (name: string): boolean => name.trim().toLowerCase() === "you";

/** "calm +0.3", from whichever of emotion and valence the worker found. */
function toneOf(speaker: SpeakerStats): string | null {
  const parts = [speaker.dominantEmotion, speaker.valence === undefined ? undefined : signed(speaker.valence, 1)];
  const text = parts.filter((part): part is string => !!part).join(" ");
  return text || null;
}

function WhoSpoke({ stats, speakers }: { stats: SpeakerStats[]; speakers: SpeakerDTO[] }) {
  const id = useId();
  const sorted = [...stats].sort((a, b) => b.talkRatio - a.talkRatio);
  // The self speaker is labelled "You" by the worker and is never "renamed"; don't offer to name it.
  const self = new Set(stats.filter((s) => s.isSelf).map((s) => s.label));
  const unnamed = speakers.find((speaker) => !speaker.renamed && !self.has(speaker.label));
  return (
    <aside className="who" aria-labelledby={id}>
      <h2 id={id} className="block-title">
        Who spoke
      </h2>
      {sorted.map((speaker) => {
        const share = Math.round(Math.min(1, Math.max(0, speaker.talkRatio)) * 100);
        const lit = Math.round((share / 100) * SEGMENTS);
        const tone = toneOf(speaker);
        return (
          <div key={speaker.label} className="who-row">
            <span className="who-head">
              <span>{speaker.isSelf && !isYou(speaker.name) ? `${speaker.name} (you)` : speaker.name}</span>
              <span className="who-share">{share}%</span>
            </span>
            <span className="who-meter-row">
              <span className="meter" role="img" aria-label={`${speaker.name} spoke ${share}% of the time`}>
                {Array.from({ length: SEGMENTS }, (_, i) => (
                  <span key={i} className={i < lit ? "meter-seg meter-seg--on" : "meter-seg"} />
                ))}
              </span>
              {tone && <span className="who-tone">{tone}</span>}
            </span>
          </div>
        );
      })}
      {unnamed && (
        <Link className="who-name" to="?tab=speakers">
          Name {unnamed.label}
        </Link>
      )}
    </aside>
  );
}
