import { expect, test } from 'bun:test';
import { remarkReleasedChangelog } from './remark-released-changelog';

const heading = (text: string, depth = 2) => ({ type: 'heading', depth, children: [{ type: 'text', value: text }] });
const paragraph = (value: string) => ({ type: 'paragraph', children: [{ type: 'text', value }] });

test('removes the whole draft section, including subsections, while preserving released notes', () => {
  const intro = paragraph('Release history');
  const release = heading('v2.1.0. August 14, 2026');
  const releasedNote = paragraph('Shipped');
  const tree = { children: [intro, heading('v2.2.0 (Unreleased)'), heading('Added', 3), paragraph('SECRET DRAFT'), release, releasedNote] };
  remarkReleasedChangelog()(tree, { path: '/content/docs/changelog.mdx' });
  expect(tree.children).toEqual([intro, release, releasedNote]);
});

test('does not remove unreleased headings from other docs', () => {
  const tree = { children: [heading('Unreleased'), paragraph('Nightly guidance')] };
  remarkReleasedChangelog()(tree, { path: '/content/docs/nightly.mdx' });
  expect(tree.children).toHaveLength(2);
});

test('removes a draft-only changelog and recognizes case-insensitive unreleased headings', () => {
  const tree = { children: [heading('v3.0.0 - UNRELEASED'), paragraph('Not shipped')] };
  remarkReleasedChangelog()(tree, { path: '/content/docs/changelog.mdx' });
  expect(tree.children).toEqual([]);
});
