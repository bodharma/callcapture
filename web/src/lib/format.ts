// Display formatting for the archive. Dates use en-GB patterns to match the
// canvas ("Thu 26 Nov, 10:00", "26.11") in the user's local time zone.

const DAY_MS = 86_400_000;

const pad2 = (n: number): string => String(n).padStart(2, "0");

/** Playback position: "15:10" below an hour, "1:02:05" from an hour. */
export function timecode(seconds: number): string {
  const total = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0;
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0 ? `${h}:${pad2(m)}:${pad2(s)}` : `${pad2(m)}:${pad2(s)}`;
}

/** US dollars with sub-cent precision kept (up to 4 decimals) and at least 2 decimals. */
export function usd(value: number): string {
  let text = value.toFixed(4);
  while (text.endsWith("0") && text.length - text.indexOf(".") > 3) text = text.slice(0, -1);
  return `$${text}`;
}

/** One cost part as the app's `CostFormat.usd` writes it: 4 decimals, "—" when unknown. */
function costPart(value: number | undefined): string {
  return value === undefined ? "—" : `$${value.toFixed(4)}`;
}

/**
 * The session cost as the app's detail view showed it:
 * "Transcription $0.1000 · Processing $0.0200 · Total $0.1200". Undefined when
 * neither part is known (the app hid the row then).
 */
export function costSplit(costs: {
  transcription?: number;
  processing?: number;
  total?: number;
}): string | undefined {
  const { transcription, processing } = costs;
  if (transcription === undefined && processing === undefined) return undefined;
  const total = costs.total ?? (transcription ?? 0) + (processing ?? 0);
  return `Transcription ${costPart(transcription)} · Processing ${costPart(processing)} · Total ${costPart(total)}`;
}

/** A signed fixed-point label, like the app's: 0.42 → "+0.42", -0.27 (1 digit) → "-0.3"; never "-0". */
export function signed(value: number, digits = 2): string {
  const text = Math.abs(value).toFixed(digits);
  const zero = Number(text) === 0;
  return `${value < 0 && !zero ? "-" : "+"}${text}`;
}

/** Recording length: "45 s", "46 min", "1 h 12 min". */
export function length(seconds: number): string {
  if (seconds < 60) return `${Math.max(0, Math.floor(seconds))} s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

const dayFormat = new Intl.DateTimeFormat("en-GB", { weekday: "short", day: "numeric", month: "short" });
const timeFormat = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const monthFormat = new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric" });

/** "Thu 26 Nov, 10:00" */
export function recordedAt(date: Date): string {
  return `${dayFormat.format(date)}, ${timeFormat.format(date)}`;
}

/** "26.11" */
export function shortDate(date: Date): string {
  return `${pad2(date.getDate())}.${pad2(date.getMonth() + 1)}`;
}

const languageNames = new Intl.DisplayNames(["en"], { type: "language" });

/** "uk" → "Ukrainian"; "auto" (or empty) → "Auto-detect", as the app labels it. */
export function languageName(code: string): string {
  if (!code || code === "auto") return "Auto-detect";
  try {
    return languageNames.of(code) ?? code;
  } catch {
    return code;
  }
}

const startOfDay = (date: Date): number =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();

/** Sidebar group: Today, Yesterday, Earlier this week (from Monday), Earlier this month, or "September 2026". */
export function dayGroup(date: Date, now: Date): string {
  const today = startOfDay(now);
  const day = startOfDay(date);
  if (day >= today) return "Today";
  if (day >= today - DAY_MS) return "Yesterday";
  const weekStart = today - ((now.getDay() + 6) % 7) * DAY_MS;
  if (day >= weekStart) return "Earlier this week";
  if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth()) {
    return "Earlier this month";
  }
  return monthFormat.format(date);
}

export type Tone = "fg" | "soft" | "ash" | "signal" | "amber" | "rust";

/** Short state word for the sidebar, coloured like the canvas (working, waiting, notes). */
export function sessionState(status: string): { word: string; tone: Tone } {
  switch (status) {
    case "recording":
      return { word: "recording", tone: "rust" };
    case "transcribing":
      return { word: "working", tone: "soft" };
    case "completed":
      return { word: "waiting", tone: "amber" };
    case "transcribed":
      return { word: "notes", tone: "signal" };
    case "error":
    case "failed":
      return { word: "failed", tone: "amber" };
    case "interrupted":
      return { word: "interrupted", tone: "ash" };
    default:
      return { word: status, tone: "ash" };
  }
}
