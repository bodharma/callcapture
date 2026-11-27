// A stand-in for the app's loopback server, for the Playwright smoke test: the
// built web UI (web/dist) plus canned JSON, one SSE stream and ranged audio. No
// app, no network. It mirrors the real server's sign-in: /login?token= sets the
// HttpOnly cc_session cookie and redirects to `next`; /api/* without it is 401.
import { randomBytes } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { LiveTurn } from "../src/api/liveTypes";
import type { SessionDTO, TranscriptLine } from "../src/api/types";
import { catalogFixture, settingsFixture } from "../src/features/settings/testData";
import { analysisFixture, sessionFixture } from "../src/test/fixtures";
import { liveFixture, systemIdle } from "../src/test/liveFixtures";

export const LOGIN_TOKEN = "e2e-token";

const DIST = fileURLToPath(new URL("../dist/", import.meta.url));
const AUDIO_SECONDS = 30;

export const session: SessionDTO = sessionFixture({ durationSec: AUDIO_SECONDS });
export const transcript: TranscriptLine[] = [
  { start: 0, end: 10, text: "Morning, everyone.", speaker: "Speaker 1", name: "Olena" },
  { start: 12, end: 22, text: "Staging has to be green by Thursday.", speaker: "Speaker 2", name: "Speaker 2" },
  { start: 24, end: 29, text: "Then we ship on Friday.", speaker: "Speaker 1", name: "Olena" },
];

export interface FixtureServer {
  readonly url: string;
  /** Secret PUT bodies by key, as the app would store them. */
  readonly savedSecrets: ReadonlyMap<string, string>;
  /** Open `/api/events` streams. */
  eventClients(): number;
  /** Sends one `liveTurn` frame to every open stream (and keeps it in `GET /api/live`). */
  emitLiveTurn(turn: LiveTurn): void;
  close(): Promise<void>;
}

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".svg": "image/svg+xml",
  ".json": "application/json",
};

function json(res: ServerResponse, status: number, body?: unknown) {
  if (body === undefined) {
    res.writeHead(status).end();
    return;
  }
  res.writeHead(status, { "content-type": "application/json; charset=utf-8" }).end(JSON.stringify(body));
}

/** A decodable 8 kHz mono 16-bit WAV with a quiet tone, so the browser can seek in it. */
function toneWav(seconds: number, rate = 8000): Buffer {
  const data = Buffer.alloc(seconds * rate * 2);
  for (let i = 0; i < seconds * rate; i += 1) {
    data.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 220 * i) / rate) * 4000), i * 2);
  }
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + data.length, 4);
  header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(rate, 24);
  header.writeUInt32LE(rate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

/** 200 with the whole file, or 206 for one `bytes=a-b` range, as the app's audio route. */
function sendAudio(req: IncomingMessage, res: ServerResponse, audio: Buffer) {
  const base = { "content-type": "audio/wav", "accept-ranges": "bytes", "cache-control": "no-store" };
  const match = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? "");
  if (!match || (match[1] === "" && match[2] === "")) {
    res.writeHead(200, { ...base, "content-length": audio.length }).end(audio);
    return;
  }
  const size = audio.length;
  const start = match[1] === "" ? Math.max(0, size - Number(match[2])) : Number(match[1]);
  const end = match[1] === "" || match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1);
  if (start >= size || start > end) {
    res.writeHead(416, { ...base, "content-range": `bytes */${size}` }).end();
    return;
  }
  res
    .writeHead(206, { ...base, "content-range": `bytes ${start}-${end}/${size}`, "content-length": end - start + 1 })
    .end(audio.subarray(start, end + 1));
}

/** Files from web/dist; any other non-API path gets index.html (the SPA routes it). */
async function sendStatic(pathname: string, res: ServerResponse) {
  const candidate = path.normalize(path.join(DIST, decodeURIComponent(pathname)));
  const inside = candidate.startsWith(DIST) && candidate !== DIST;
  const isFile = inside && (await stat(candidate).catch(() => null))?.isFile();
  const file = isFile ? candidate : path.join(DIST, "index.html");
  const body = await readFile(file).catch(() => null);
  if (!body) {
    res.writeHead(503, { "content-type": "text/plain" }).end("web/dist is missing: run `npm run build` first.");
    return;
  }
  res.writeHead(200, { "content-type": CONTENT_TYPES[path.extname(file)] ?? "application/octet-stream" }).end(body);
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  let text = "";
  for await (const chunk of req) text += String(chunk);
  return text ? JSON.parse(text) : undefined;
}

function cookieSession(req: IncomingMessage): string | undefined {
  return /(?:^|;\s*)cc_session=([^;]+)/.exec(req.headers.cookie ?? "")?.[1];
}

export async function startFixtureServer(): Promise<FixtureServer> {
  const sessions = new Set<string>();
  const secrets = new Map<string, string>();
  const streams = new Set<ServerResponse>();
  let live = liveFixture({ turns: [], partials: {}, usage: undefined });
  const audio = toneWav(AUDIO_SECONDS);
  const settings = () =>
    settingsFixture((s) => {
      for (const key of ["openrouter", "assemblyai", "deepgram", "remote"] as const) s.secrets[key].set = secrets.has(key);
    });

  const api = async (req: IncomingMessage, res: ServerResponse, url: URL) => {
    const route = `${req.method} ${url.pathname}`;
    const secret = /^PUT \/api\/settings\/secrets\/(\w+)$/.exec(route);
    if (secret) {
      const { value } = (await readBody(req)) as { value: string };
      secrets.set(secret[1], value);
      return json(res, 204);
    }
    switch (route) {
      case "GET /api/events":
        res.writeHead(200, { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-cache" });
        res.write(`event: hello\ndata: ${JSON.stringify({ online: true, recording: "idle", blocked: false, button: systemIdle.button })}\n\n`);
        streams.add(res);
        req.on("close", () => streams.delete(res));
        return;
      case "GET /api/system":
        return json(res, 200, systemIdle);
      case "GET /api/sessions":
        return json(res, 200, [session]);
      case "GET /api/search":
        return json(res, 200, []);
      case "GET /api/sessions/options":
        return json(res, 200, { recordingTypes: [{ value: "call_meeting", label: "Call / Meeting" }], languages: [{ value: "uk", label: "Ukrainian" }, { value: "en", label: "English" }] });
      case "GET /api/sessions/S1":
        return json(res, 200, session);
      case "GET /api/sessions/S1/transcript":
        return json(res, 200, transcript);
      case "GET /api/sessions/S1/note":
        return json(res, 200, { markdown: "# Weekly sync\n\nShip on Friday if staging is green." });
      case "GET /api/sessions/S1/analysis":
        return json(res, 200, analysisFixture);
      case "GET /api/sessions/S1/speakers":
        return json(res, 200, [{ label: "Speaker 1", name: "Olena", renamed: true }, { label: "Speaker 2", name: "Speaker 2", renamed: false }]);
      case "GET /api/sessions/S1/peaks":
        return json(res, 200, Array.from({ length: 120 }, (_, i) => 0.3 + 0.3 * Math.sin(i / 5)));
      case "GET /api/sessions/S1/markers":
        return json(res, 200, []);
      case "GET /api/sessions/S1/audio":
        return sendAudio(req, res, audio);
      case "GET /api/settings":
        return json(res, 200, settings());
      case "GET /api/catalog":
      case "POST /api/catalog/refresh":
        return json(res, 200, catalogFixture());
      case "GET /api/live":
        return json(res, 200, live);
      default:
        return json(res, 404, { error: "not_found" });
    }
  };

  const server = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (url.pathname === "/login") {
      if (url.searchParams.get("token") !== LOGIN_TOKEN) return json(res, 401, { error: "signin" });
      const id = randomBytes(16).toString("hex");
      sessions.add(id);
      const next = url.searchParams.get("next") ?? "/";
      const location = next.startsWith("/") && !next.startsWith("//") ? next : "/";
      res.writeHead(302, { location, "set-cookie": `cc_session=${id}; Path=/; HttpOnly; SameSite=Strict` }).end();
      return;
    }
    if (url.pathname === "/api" || url.pathname.startsWith("/api/")) {
      const id = cookieSession(req);
      if (!id || !sessions.has(id)) return json(res, 401, { error: "signin" });
      api(req, res, url).catch((error: unknown) => json(res, 500, { error: "failed", message: String(error) }));
      return;
    }
    void sendStatic(url.pathname, res);
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}`,
    savedSecrets: secrets,
    eventClients: () => streams.size,
    emitLiveTurn(turn) {
      live = { ...live, turns: [...live.turns, turn] };
      for (const stream of streams) stream.write(`event: liveTurn\ndata: ${JSON.stringify(turn)}\n\n`);
    },
    close: () =>
      new Promise<void>((resolve) => {
        for (const stream of streams) stream.end();
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}
