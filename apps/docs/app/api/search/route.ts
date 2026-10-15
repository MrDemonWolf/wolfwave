import { source } from '@/lib/source';
import { createFromSource } from 'fumadocs-core/search/server';

// Static export: the search index is built once at build time, never revalidated.
export const revalidate = false;

/** Static search index consumed by `components/search.tsx` (see `staticGET`). */
export const { staticGET: GET } = createFromSource(source, {
  // Explicit: the server default is 'multilingual', but the client-side
  // index is created with 'english', so the two must match.
  language: 'english',
});
