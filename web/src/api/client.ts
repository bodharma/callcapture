/** Thrown when the server answers 401: the session cookie is missing or expired. */
export class SignInRequired extends Error {
  constructor() {
    super("Sign in required");
    this.name = "SignInRequired";
  }
}

/**
 * Any non-2xx, non-401 answer. The server sends `{"error": code, "message"?: text}`;
 * `code` is the `error` field and `message` is `message`, else `error` (a refused
 * re-process puts its reason text in `error`), else the status text.
 */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly code?: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function toApiError(response: Response): Promise<ApiError> {
  const fallback = response.statusText || `HTTP ${response.status}`;
  try {
    const body: unknown = await response.json();
    if (body && typeof body === "object") {
      const { error, message } = body as { error?: unknown; message?: unknown };
      const code = typeof error === "string" ? error : undefined;
      const text = typeof message === "string" && message ? message : code;
      return new ApiError(response.status, text || fallback, code);
    }
  } catch {
    // Non-JSON error body: fall through to the status text.
  }
  return new ApiError(response.status, fallback);
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const init: RequestInit = { method, credentials: "same-origin" };
  if (body !== undefined) {
    init.headers = { "Content-Type": "application/json" };
    init.body = JSON.stringify(body);
  }
  const response = await fetch(path, init);
  if (response.status === 401) throw new SignInRequired();
  if (!response.ok) throw await toApiError(response);
  // 204, or any 2xx with an empty body, has nothing to parse.
  const text = await response.text();
  return (text.trim() === "" ? undefined : JSON.parse(text)) as T;
}

export function apiGet<T>(path: string): Promise<T> {
  return request<T>("GET", path);
}

export function apiSend<T>(method: string, path: string, body?: unknown): Promise<T> {
  return request<T>(method, path, body);
}

/** A sentence for the user: the server's message, or what to check when the app didn't answer. */
export function errorText(error: unknown): string {
  if (error instanceof ApiError) return sentence(error.message);
  return "CallCapture didn't answer. Check that the app is running, then try again.";
}

function sentence(text: string): string {
  const trimmed = text.trim();
  return /[.!?]$/.test(trimmed) ? trimmed : `${trimmed}.`;
}
