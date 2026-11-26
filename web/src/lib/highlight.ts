export interface Part {
  text: string;
  hit: boolean;
}

/** Lower-cased with diacritics removed, one entry per UTF-16 unit of the source. */
function fold(text: string): { folded: string; sourceIndex: number[] } {
  let folded = "";
  const sourceIndex: number[] = [];
  for (let i = 0; i < text.length; i += 1) {
    const plain = text[i].normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
    for (let j = 0; j < plain.length; j += 1) {
      folded += plain[j];
      sourceIndex.push(i);
    }
  }
  return { folded, sourceIndex };
}

/**
 * Splits `text` into marked and unmarked parts for every match of `query`,
 * case- and diacritic-insensitive like the server's search. The query is
 * plain text, never a pattern. No match gives the whole text unmarked.
 */
export function highlightParts(text: string, query: string): Part[] {
  const needle = fold(query.trim()).folded;
  if (!needle) return [{ text, hit: false }];
  const { folded, sourceIndex } = fold(text);
  const parts: Part[] = [];
  let cursor = 0;
  let from = folded.indexOf(needle);
  while (from !== -1) {
    const start = sourceIndex[from];
    const end = sourceIndex[from + needle.length - 1] + 1;
    if (start > cursor) parts.push({ text: text.slice(cursor, start), hit: false });
    parts.push({ text: text.slice(start, end), hit: true });
    cursor = end;
    from = folded.indexOf(needle, from + needle.length);
  }
  if (cursor < text.length) parts.push({ text: text.slice(cursor), hit: false });
  return parts.length > 0 ? parts : [{ text, hit: false }];
}
