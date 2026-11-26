type Listener = (event: MessageEvent) => void;

/**
 * Stands in for the browser's EventSource (jsdom has none). Tests drive it:
 * `open()`, `fail()` and `emit(name, payload)` on the latest instance.
 */
export class FakeEventSource {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSED = 2;
  static instances: FakeEventSource[] = [];

  /** The most recently created connection. */
  static latest(): FakeEventSource {
    const latest = FakeEventSource.instances.at(-1);
    if (!latest) throw new Error("no EventSource was opened");
    return latest;
  }

  /** Connections not closed yet. */
  static open(): FakeEventSource[] {
    return FakeEventSource.instances.filter((source) => source.readyState !== FakeEventSource.CLOSED);
  }

  readyState = FakeEventSource.CONNECTING;
  onopen: ((event: Event) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessage: Listener | null = null;
  private readonly listeners = new Map<string, Set<Listener>>();

  constructor(
    readonly url: string,
    readonly init?: { withCredentials?: boolean },
  ) {
    FakeEventSource.instances.push(this);
  }

  addEventListener(type: string, listener: Listener) {
    const set = this.listeners.get(type) ?? new Set<Listener>();
    set.add(listener);
    this.listeners.set(type, set);
  }

  removeEventListener(type: string, listener: Listener) {
    this.listeners.get(type)?.delete(listener);
  }

  close() {
    this.readyState = FakeEventSource.CLOSED;
  }

  // Test controls

  open() {
    this.readyState = FakeEventSource.OPEN;
    this.onopen?.(new Event("open"));
  }

  fail() {
    this.readyState = FakeEventSource.CONNECTING;
    this.onerror?.(new Event("error"));
  }

  emit(type: string, payload: unknown) {
    this.emitRaw(type, JSON.stringify(payload));
  }

  emitRaw(type: string, data: string) {
    if (this.readyState === FakeEventSource.CLOSED) return;
    const event = new MessageEvent(type, { data });
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }
}
