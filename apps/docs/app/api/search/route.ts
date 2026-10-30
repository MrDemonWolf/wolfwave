import { source } from '@/lib/source';
import { tabIdForUrl } from '@/lib/docs-tree';
import { createFromSource } from 'fumadocs-core/search/server';

// Static export: the search index is built once at build time, never revalidated.
export const revalidate = false;

/**
 * Static search index consumed by `components/search.tsx` (see `staticGET`).
 * Each page is tagged with its sidebar tab, so the dialog can filter to
 * Guides, Developers, or Design.
 */
export const { staticGET: GET } = createFromSource(source, {
  // Explicit: the server default is 'multilingual', but the client-side
  // index is created with 'english', so the two must match.
  language: 'english',
  buildIndex(page) {
    return {
      id: page.url,
      url: page.url,
      title: page.data.title,
      description: page.data.description,
      structuredData: page.data.structuredData,
      tag: tabIdForUrl(source.getPageTree(), page.url) ?? 'guides',
    };
  },
});
