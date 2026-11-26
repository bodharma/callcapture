import { useState } from "react";
import Markdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";

/** Notes longer than this open folded, with a button to show the rest. */
const FOLD_AT = 1_500;

const isExternal = (href: string | undefined): boolean => !!href && /^(https?:|mailto:)/i.test(href);

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
    isExternal(href) ? (
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
    return isExternal(href) ? (
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
  const body = noteBody(markdown);
  const long = body.length > FOLD_AT;
  const [open, setOpen] = useState(false);

  return (
    <div className="note-wrap">
      <div className={long && !open ? "note note--folded" : "note"} id="session-note">
        <Markdown remarkPlugins={[remarkGfm]} components={components}>
          {body}
        </Markdown>
      </div>
      {long && (
        <button
          type="button"
          className="btn btn--small btn--quiet"
          aria-expanded={open}
          aria-controls="session-note"
          onClick={() => setOpen((value) => !value)}
        >
          {open ? "Show less" : "Show the whole note"}
        </button>
      )}
    </div>
  );
}
