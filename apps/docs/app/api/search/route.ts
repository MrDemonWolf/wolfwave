import { source } from '@/lib/source';
import { createFromSource } from 'fumadocs-core/search/server';

export const revalidate = false;

export const { staticGET: GET } = createFromSource(source, {
  // Explicit: the server default is 'multilingual', but the client-side
  // index is created with 'english', so the two must match.
  language: 'english',
});
