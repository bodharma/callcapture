/** Thrown when the server answers 401: the session cookie is missing or expired. */
export class SignInRequired extends Error {
  constructor() {
    super("Sign in required");
    this.name = "SignInRequired";
  }
}

/** Any non-2xx, non-401 answer; `message` is the server's `error` field when present. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function errorMessage(response: Response): Promise<string> {
  try {
    const body: unknown = await response.json();
    if (body && typeof body === "object" && "error" in body && typeof body.error === "string") {
      return body.error;
    }
  } catch {
    // Non-JSON error body: fall through to the status text.
  }
  return response.statusText || `HTTP ${response.status}`;
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const init: RequestInit = { method, credentials: "same-origin" };
  if (body !== undefined) {
    init.headers = { "Content-Type": "application/json" };
    init.body = JSON.stringify(body);
  }
  const response = await fetch(path, init);
  if (response.status === 401) throw new SignInRequired();
  if (!response.ok) throw new ApiError(response.status, await errorMessage(response));
  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

export function apiGet<T>(path: string): Promise<T> {
  return request<T>("GET", path);
}

export function apiSend<T>(method: string, path: string, body?: unknown): Promise<T> {
  return request<T>(method, path, body);
}
