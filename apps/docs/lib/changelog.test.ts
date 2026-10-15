import { expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { parseLatestChangelog } from './changelog';

const sample = `# Changelog

## v2.2.0 (Unreleased)

### Added

- **Unreleased thing.** Not shipped.

## v2.1.0. August 14, 2026

### Added
- **Custom bot commands.** Make your own.
- **Approve songs.** Opt in.
- plain bullet
- **Fair-share.** Round robin.
- **Fourth.** Dropped.

## v2.0.1. July 11, 2026

- **Old.** Older.
`;

test('skips the unreleased block and reads the dot-separated date', () => {
  expect(parseLatestChangelog(sample)).toEqual({
    version: '2.1.0',
    date: 'August 14, 2026',
    highlights: ['Custom bot commands.', 'Approve songs.', 'Fair-share.'],
  });
});

test('accepts the dash-separated heading shape', () => {
  const raw = '## v1.0.0 - May 1, 2026\n\n- **Launch.** Hi.\n';
  expect(parseLatestChangelog(raw)).toEqual({ version: '1.0.0', date: 'May 1, 2026', highlights: ['Launch.'] });
  expect(parseLatestChangelog('## v1.0.0 – May 1, 2026\n- **A.** b\n')?.date).toBe('May 1, 2026');
});

test('returns null with only an unreleased block', () => {
  expect(parseLatestChangelog('## v2.2.0 (Unreleased)\n\n- **X.** y\n')).toBeNull();
});

test('parses the real changelog.mdx', () => {
  const raw = readFileSync(new URL('../content/docs/changelog.mdx', import.meta.url), 'utf-8');
  const info = parseLatestChangelog(raw);
  expect(info).not.toBeNull();
  expect(info?.date).not.toMatch(/unreleased/i);
  expect(info?.highlights.length).toBeGreaterThan(0);
});
