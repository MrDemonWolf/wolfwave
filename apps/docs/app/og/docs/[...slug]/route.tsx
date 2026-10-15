import { type ChangelogInfo, parseLatestChangelog } from '@/lib/changelog';
import { getPageImage, source } from '@/lib/source';
import { notFound } from 'next/navigation';
import { ImageResponse } from 'next/og';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import {
  OgCard,
  ChangelogOgCard,
  OG_SIZE,
  loadOgFonts,
} from '../../_components/og-card';
import { presetForSlug } from '../../_components/og-presets';

// Static export: every card is rendered at build time via generateStaticParams.
export const revalidate = false;
export const dynamic = 'force-static';

/** Reads `content/docs/changelog.mdx` and parses the latest released version; null falls back to the generic card. */
function readLatestChangelog(): ChangelogInfo | null {
  try {
    const filePath = path.join(process.cwd(), 'content/docs/changelog.mdx');
    return parseLatestChangelog(readFileSync(filePath, 'utf-8'));
  } catch {
    return null;
  }
}

/**
 * Renders one docs page's social card as a PNG. The last URL segment is the
 * `image.png` filename (see `getPageImage`), so it is dropped to recover the
 * page slug. Frontmatter `og*` fields win over the section preset.
 */
export async function GET(_req: Request, { params }: RouteContext<'/og/docs/[...slug]'>) {
  const { slug } = await params;
  const pageSlug = slug.slice(0, -1);
  const page = source.getPage(pageSlug);
  if (!page) notFound();

  const fonts = await loadOgFonts();
  const preset = presetForSlug(pageSlug);
  const isChangelog = pageSlug[0] === 'changelog';

  const chips = page.data.ogChips ?? preset.chips;
  const eyebrow = page.data.ogEyebrow ?? preset.eyebrow;

  if (isChangelog) {
    const cl = readLatestChangelog();
    if (cl) {
      return new ImageResponse(
        <ChangelogOgCard version={cl.version} date={cl.date} highlights={cl.highlights} />,
        {
          ...OG_SIZE,
          fonts: fonts.map((f) => ({ name: f.name, data: f.data, weight: f.weight as 400 | 500 | 700, style: f.style })),
        },
      );
    }
  }

  return new ImageResponse(
    (
      <OgCard
        eyebrow={eyebrow}
        title={page.data.ogTitle ?? page.data.title}
        description={page.data.ogDescription ?? page.data.description}
        chips={chips}
      />
    ),
    {
      ...OG_SIZE,
      fonts: fonts.map((f) => ({ name: f.name, data: f.data, weight: f.weight as 400 | 500 | 700, style: f.style })),
    },
  );
}

/** One param set per docs page so the static export emits every card. */
export function generateStaticParams() {
  return source.getPages().map((page) => ({
    lang: page.locale,
    slug: getPageImage(page).segments,
  }));
}
