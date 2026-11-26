import Markdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";

/**
 * True when `href` leaves the app's origin once resolved: absolute URLs,
 * protocol-relative `//host`, backslash `/\host` and `mailto:` all count.
 * Unparseable links count as internal (react-markdown has already dropped
 * dangerous schemes).
 */
export function isExternalHref(href: string | undefined, base: string = window.location.href): boolean {
  if (!href) return false;
  try {
    return new URL(href, base).origin !== new URL(base).origin;
  } catch {
    return false;
  }
}

/**
 * The note text comes from transcripts, so it is untrusted:
 * - raw HTML stays escaped (no rehype-raw), and react-markdown's default URL
 *   filter drops `javascript:` and similar links;
 * - images never load (a remote image would call out when the page opens);
 *   they show as a link with their alt text instead;
 * - external links open outside the app;
 * - task-list tick boxes are dropped: action items are a plain list for now.
 */
const components: Components = {
  a: ({ node: _node, href, children, ...rest }) =>
    isExternalHref(href) ? (
      <a {...rest} href={href} target="_blank" rel="noopener noreferrer">
        {children}
      </a>
    ) : (
      <a {...rest} href={href}>
        {children}
      </a>
    ),
  img: ({ src, alt }) => {
    const label = alt?.trim() || "Image";
    const href = typeof src === "string" ? src : undefined;
    return isExternalHref(href) ? (
      <a className="note-image" href={href} target="_blank" rel="noopener noreferrer">
        {label}
      </a>
    ) : (
      <span className="note-image">{label}</span>
    );
  },
  input: () => null,
};

/**
 * Drops what the page already shows: a leading YAML front matter block (the
 * vault note's metadata) and the note's own top heading (the session title).
 */
export function noteBody(markdown: string): string {
  return markdown
    .replace(/^---\r?\n[\s\S]*?\r?\n---[ \t]*(\r?\n|$)/, "")
    .replace(/^\s*# [^\n]*\n?/, "");
}

export function Note({ markdown }: { markdown: string }) {
  return (
    <div className="note">
      <Markdown remarkPlugins={[remarkGfm]} components={components}>
        {noteBody(markdown)}
      </Markdown>
    </div>
  );
}
