import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getPageImage, source } from '@/lib/source';
import { pageUrl, repoUrl } from '@/lib/site';
import { jsonLdScript } from '@/lib/seo';
import { getMDXComponents } from '@/mdx-components';
import styles from './page.module.css';

const title = 'WolfWave Changelog: Mac App Updates & Release Notes';
const description = 'See what shipped in WolfWave. Explore new Apple Music features, Twitch song request improvements, Discord updates, and OBS overlay fixes for Mac.';
const url = pageUrl('/changelog');

/** Public release notes reuse the canonical MDX; the compiler removes draft releases. */
export function generateMetadata(): Metadata {
  const page = source.getPage(['changelog']);
  if (!page) notFound();
  const image = getPageImage(page).url;
  return {
    title: { absolute: title },
    description,
    keywords: ['WolfWave changelog', 'WolfWave release notes', 'Apple Music OBS overlay updates', 'Mac Twitch song requests'],
    alternates: { canonical: url },
    openGraph: {
      type: 'website', url, siteName: 'WolfWave', title, description,
      images: [{ url: image, width: 1200, height: 630, alt: 'The latest released WolfWave version and its highlights.' }],
    },
    twitter: { card: 'summary_large_image', site: '@mrdemonwolf', creator: '@mrdemonwolf', title, description, images: [image] },
  };
}

export default function ChangelogPage() {
  const page = source.getPage(['changelog']);
  if (!page) notFound();
  const MDX = page.data.body;
  const jsonLd = {
    '@context': 'https://schema.org',
    '@graph': [
      { '@type': 'CollectionPage', name: title, description, url, inLanguage: 'en-US' },
      { '@type': 'BreadcrumbList', itemListElement: [
        { '@type': 'ListItem', position: 1, name: 'Home', item: pageUrl('/') },
        { '@type': 'ListItem', position: 2, name: 'Changelog', item: url },
      ] },
    ],
  };
  return (
    <main id="nd-page" tabIndex={-1} className={`ww-font ww-bg-base ${styles.page}`}>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLdScript(jsonLd) }} />
      <header className={styles.header}>
        <span className="ww-kicker">WOLFWAVE CHANGELOG</span>
        <h1>Good things<br /><span className="ww-text-brand">keep shipping.</span></h1>
        <p>Every WolfWave update, in plain language. Follow the features, refinements, and fixes that make your stream feel more like you.</p>
        <div className={styles.actions}>
          <Link href="/download" className="ww-btn ww-btn-primary">Get WolfWave</Link>
          <a href={`${repoUrl}/releases`} className="ww-btn ww-btn-secondary">Releases on GitHub <span aria-hidden="true">↗</span></a>
        </div>
      </header>
      <article aria-label="Released versions" className={styles.releases}>
        <MDX components={getMDXComponents()} />
      </article>
      <aside className={styles.closing}>
        <p>Have an idea for the next update?</p>
        <a href={`${repoUrl}/issues`} className="ww-btn ww-btn-secondary">Share feedback <span aria-hidden="true">↗</span></a>
      </aside>
    </main>
  );
}
