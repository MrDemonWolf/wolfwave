import { getPageImage, source } from '@/lib/source';
import {
  DocsBody,
  DocsDescription,
  DocsPage,
  DocsTitle,
  MarkdownCopyButton,
} from 'fumadocs-ui/layouts/notebook/page';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getMDXComponents } from '@/mdx-components';
import type { Metadata } from 'next';
import { createRelativeLink } from 'fumadocs-ui/mdx';
import { ChevronRight, SquarePen } from 'lucide-react';
import { docsCrumbs } from '@/lib/docs-tree';
import { pageUrl, repoUrl } from '@/lib/site';
import { docsPageLd, docsTitle, jsonLdScript, lastCommitDate } from '@/lib/seo';

const updatedFormat = new Intl.DateTimeFormat('en-US', { dateStyle: 'long', timeZone: 'UTC' });

/**
 * One MDX docs page: breadcrumb (tab › group) and page actions, the title and
 * lede, the body, then "last updated" and an edit link above Fumadocs'
 * previous/next cards. TechArticle + BreadcrumbList JSON-LD (see `lib/seo.ts`).
 * The docs home renders its own hero and `<h1>` from MDX, so it skips the header.
 */
export default async function Page(props: PageProps<'/docs/[[...slug]]'>) {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  const MDX = page.data.body;
  const url = pageUrl(params.slug?.join('/') === 'changelog' ? '/changelog' : page.url);
  const isDocsRoot = !params.slug?.length;
  const absolutePath = (page as { absolutePath?: string }).absolutePath;
  const updated = lastCommitDate(absolutePath);
  const editUrl = `${repoUrl}/blob/main/apps/docs/content/docs/${page.path}`;
  const crumbs = docsCrumbs(source.getPageTree(), page.url);

  const jsonLd = docsPageLd({
    url,
    title: page.data.title,
    description: page.data.description,
    dateModified: updated,
    isDocsRoot,
  });

  return (
    <DocsPage
      toc={page.data.toc}
      full={page.data.full}
      breadcrumb={{ enabled: false }}
      tableOfContent={{ style: 'clerk' }}
      // Full-width pages (the docs home) have no TOC, so no "On this page" bar either.
      tableOfContentPopover={{ style: 'clerk', ...(page.data.full ? { enabled: false } : {}) }}
    >
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLdScript(jsonLd) }}
      />
      {/* The docs root's MDX hero carries the page's one <h1>, so the
          frontmatter title and description are not rendered there. */}
      {isDocsRoot ? null : (
        <header className="ww-page-head">
          <div className="ww-page-meta">
            {crumbs ? (
              <nav aria-label="Breadcrumb" className="ww-crumbs">
                <Link href={crumbs.tab.url}>{crumbs.tab.title}</Link>
                {crumbs.group ? (
                  <>
                    <ChevronRight aria-hidden="true" />
                    <span>{crumbs.group}</span>
                  </>
                ) : null}
              </nav>
            ) : (
              <span />
            )}
            <div className="ww-page-actions">
              <MarkdownCopyButton markdownUrl={`/llms.mdx${page.url}.md`} />
            </div>
          </div>
          <DocsTitle>{page.data.title}</DocsTitle>
          <DocsDescription>{page.data.description}</DocsDescription>
        </header>
      )}
      <DocsBody>
        <MDX
          components={getMDXComponents({
            // this allows you to link to other pages with relative file paths
            a: createRelativeLink(source, page),
          })}
        />
      </DocsBody>
      <div className="ww-page-end">
        {updated ? (
          <p>
            Last updated <time dateTime={updated.toISOString()}>{updatedFormat.format(updated)}</time>
          </p>
        ) : (
          <span />
        )}
        <a href={editUrl} target="_blank" rel="noopener noreferrer">
          <SquarePen aria-hidden="true" />
          Edit this page
        </a>
      </div>
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

  const isChangelog = params.slug?.join('/') === 'changelog';
  const url = pageUrl(isChangelog ? '/changelog' : page.url);
  const ogImage = getPageImage(page).url;
  const ogTitle = page.data.ogTitle ?? page.data.title;
  const ogDescription = page.data.ogDescription ?? page.data.description;
  const alt = `${ogTitle}. WolfWave for Apple Music on macOS (Twitch, Discord, OBS)`;
  const pageKeywords = page.data.keywords ?? [];

  return {
    title: docsTitle(page.data.metaTitle ?? page.data.title),
    description: page.data.description,
    ...(isChangelog ? { robots: { index: false, follow: true } } : {}),
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
