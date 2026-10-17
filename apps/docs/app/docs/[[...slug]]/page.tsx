import { getPageImage, source } from '@/lib/source';
import { DocsBody, DocsDescription, DocsPage, DocsTitle } from 'fumadocs-ui/layouts/docs/page';
import { notFound } from 'next/navigation';
import { getMDXComponents } from '@/mdx-components';
import type { Metadata } from 'next';
import { createRelativeLink } from 'fumadocs-ui/mdx';
import { pageUrl } from '@/lib/site';
import { docsPageLd, docsTitle, jsonLdScript, lastCommitDate } from '@/lib/seo';

/** Renders one MDX docs page with TechArticle + BreadcrumbList JSON-LD (see `lib/seo.ts`). */
export default async function Page(props: PageProps<'/docs/[[...slug]]'>) {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  const MDX = page.data.body;
  const url = pageUrl(page.url);
  const isDocsRoot = !params.slug?.length;
  // Route-level eyebrow above the title. Skips the docs root (index.mdx renders
  // its own eyebrow inside .docs-hero).
  const eyebrow = isDocsRoot ? undefined : page.data.ogEyebrow;

  const jsonLd = docsPageLd({
    url,
    title: page.data.title,
    description: page.data.description,
    dateModified: lastCommitDate((page as { absolutePath?: string }).absolutePath),
    isDocsRoot,
  });

  return (
    <DocsPage toc={page.data.toc} full={page.data.full}>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLdScript(jsonLd) }}
      />
      {eyebrow ? <span className="docs-eyebrow">{eyebrow}</span> : null}
      {/* The docs root's MDX hero carries the page's one <h1>, so the
          frontmatter title and description are not rendered there. */}
      {isDocsRoot ? null : (
        <>
          <DocsTitle>{page.data.title}</DocsTitle>
          <DocsDescription>{page.data.description}</DocsDescription>
        </>
      )}
      <DocsBody>
        <MDX
          components={getMDXComponents({
            // this allows you to link to other pages with relative file paths
            a: createRelativeLink(source, page),
          })}
        />
      </DocsBody>
    </DocsPage>
  );
}

/** Static export: one param set per docs page. */
export async function generateStaticParams() {
  return source.generateParams();
}

/** Keywords merged into every page's own `keywords` frontmatter. */
const GLOBAL_KEYWORDS = [
  'WolfWave',
  'Apple Music',
  'Twitch',
  'Discord',
  'macOS',
  'menu bar',
  'now playing',
  'stream overlay',
  'OBS',
  'open source',
];

/**
 * Per-page metadata. `<title>` is `metaTitle` (search-intent wording) when set,
 * else the visible `title`; see `docsTitle` for the double-brand rule. Canonical, OpenGraph/Twitter cards (image from `getPageImage`), merged keywords. */
export async function generateMetadata(props: PageProps<'/docs/[[...slug]]'>): Promise<Metadata> {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  const url = pageUrl(page.url);
  const ogImage = getPageImage(page).url;
  const ogTitle = page.data.ogTitle ?? page.data.title;
  const ogDescription = page.data.ogDescription ?? page.data.description;
  const alt = `${ogTitle}. WolfWave for Apple Music on macOS (Twitch, Discord, OBS)`;
  const pageKeywords = page.data.keywords ?? [];

  return {
    title: docsTitle(page.data.metaTitle ?? page.data.title),
    description: page.data.description,
    keywords: [...new Set([...pageKeywords, ...GLOBAL_KEYWORDS])],
    alternates: {
      canonical: url,
    },
    openGraph: {
      type: 'article',
      url,
      siteName: 'WolfWave',
      title: ogTitle,
      description: ogDescription,
      images: [
        {
          url: ogImage,
          width: 1200,
          height: 630,
          alt,
        },
      ],
    },
    twitter: {
      card: 'summary_large_image',
      site: '@mrdemonwolf',
      creator: '@mrdemonwolf',
      title: ogTitle,
      description: ogDescription,
      images: [ogImage],
    },
  };
}
