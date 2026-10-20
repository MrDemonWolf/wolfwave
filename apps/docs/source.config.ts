import { defineConfig, defineDocs } from 'fumadocs-mdx/config';
// fumadocs-mdx 14.3+ deprecated its forwarded schemas; the core ones are canonical.
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';
import { z } from 'zod';
import { remarkReleasedChangelog } from './lib/remark-released-changelog';

// Adds the SEO / Open Graph fields read by `app/og/docs/[...slug]/route.tsx`
// and page metadata; all optional so existing pages stay valid.
const extendedFrontmatter = pageSchema.extend({
  keywords: z.array(z.string()).optional(),
  section: z.string().optional(),
  ogChips: z.array(z.string()).optional(),
  ogEyebrow: z.string().optional(),
  ogTitle: z.string().optional(),
  ogDescription: z.string().optional(),
  // `<title>` override for search results when the sidebar/visible title is
  // too short to say what the page is for ("Install"). Not shown on the page.
  metaTitle: z.string().optional(),
});

// You can customise Zod schemas for frontmatter and `meta.json` here
// see https://fumadocs.dev/docs/mdx/collections
export const docs = defineDocs({
  dir: 'content/docs',
  docs: {
    schema: extendedFrontmatter,
    postprocess: {
      // Keeps processed markdown so `getLLMText` (llms-full.txt) can read it.
      includeProcessedMarkdown: true,
    },
  },
  meta: {
    schema: metaSchema,
  },
});

export default defineConfig({
  mdxOptions: {
    remarkPlugins: [remarkReleasedChangelog],
  },
});
