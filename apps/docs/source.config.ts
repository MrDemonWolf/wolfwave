import { defineConfig, defineDocs } from 'fumadocs-mdx/config';
// fumadocs-mdx 14.3+ deprecated its forwarded schemas; the core ones are canonical.
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';
import { z } from 'zod';

const extendedFrontmatter = pageSchema.extend({
  keywords: z.array(z.string()).optional(),
  section: z.string().optional(),
  ogChips: z.array(z.string()).optional(),
  ogEyebrow: z.string().optional(),
  ogTitle: z.string().optional(),
  ogDescription: z.string().optional(),
});

// You can customise Zod schemas for frontmatter and `meta.json` here
// see https://fumadocs.dev/docs/mdx/collections
export const docs = defineDocs({
  dir: 'content/docs',
  docs: {
    schema: extendedFrontmatter,
    postprocess: {
      includeProcessedMarkdown: true,
    },
  },
  meta: {
    schema: metaSchema,
  },
});

export default defineConfig({
  mdxOptions: {
    // MDX options
  },
});
