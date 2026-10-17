import { docs } from 'fumadocs-mdx:collections/server';
import { type InferPageType, loader } from 'fumadocs-core/source';
import { absoluteUrl, pageUrl } from './site';

// See https://fumadocs.dev/docs/headless/source-api for more info
export const source = loader({
  baseUrl: '/docs',
  source: docs.toFumadocsSource(),
  plugins: [],
});

/** Returns the OG-image slug segments + absolute URL for a docs page's social card. */
export function getPageImage(page: InferPageType<typeof source>) {
  const segments = [...page.slugs, 'image.png'];

  return {
    segments,
    url: absoluteUrl(`/og/docs/${segments.join('/')}`),
  };
}

/**
 * Renders a docs page as plain markdown for the llms-full.txt export: title,
 * canonical URL, one-line description, then the processed body.
 */
export async function getLLMText(page: InferPageType<typeof source>) {
  const processed = await page.data.getText('processed');
  const description = page.data.description ? `\n\n> ${page.data.description}` : '';

  return `# ${page.data.title}

URL: ${pageUrl(page.url)}${description}

${processed}`;
}
