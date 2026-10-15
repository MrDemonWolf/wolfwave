/** Fields the changelog card shows: newest released version, its date text, and up to three bold bullet leads. */
export interface ChangelogInfo {
  version: string;
  date: string;
  highlights: string[];
}

/** Matches `## v2.1.0. August 14, 2026`, `## v2.1.0 - August 14, 2026`, and `## v2.2.0 (Unreleased)`. */
const HEADING_RE = /^##\s+v(\d[\d.]*?)\.?(?:\s*[–—-]\s*|\.\s+|\s+)(.+?)\s*$/;

/**
 * Parses the latest *released* version out of the changelog MDX: the first
 * `## vX.Y.Z` section whose heading is not marked `(Unreleased)`, with its
 * date text and the first three bullets that start with a bold lead.
 * An unreleased block is skipped so the card never advertises an untagged version.
 * Returns null when no released section has a bold bullet.
 */
export function parseLatestChangelog(raw: string): ChangelogInfo | null {
  const lines = raw.split('\n');
  const headings: { index: number; version: string; date: string }[] = [];
  lines.forEach((line, index) => {
    const m = HEADING_RE.exec(line);
    if (m) headings.push({ index, version: m[1], date: m[2] });
  });

  for (let i = 0; i < headings.length; i++) {
    const { index, version, date } = headings[i];
    if (/^\(?\s*unreleased\s*\)?$/i.test(date)) continue;
    const end = i + 1 < headings.length ? headings[i + 1].index : lines.length;
    const section = lines.slice(index + 1, end).join('\n');

    const bulletRe = /^[-*]\s+\*\*([^*]+)\*\*/gm;
    const highlights: string[] = [];
    let m: RegExpExecArray | null;
    while ((m = bulletRe.exec(section)) !== null && highlights.length < 3) {
      highlights.push(m[1].trim());
    }
    return highlights.length === 0 ? null : { version, date, highlights };
  }
  return null;
}
