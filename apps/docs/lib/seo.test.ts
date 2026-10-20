import { describe, expect, test } from 'bun:test';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

/**
 * SEO guard over the BUILT site (`out/`), not the source: metadata merging,
 * MDX headings, and JSON-LD only exist in their final form after `next build`.
 *
 * Run after a build: `bun run build --filter docs && bun run --filter docs test`.
 * With no `out/`, the suite is skipped locally but fails under CI, so the gate
 * cannot pass silently in the job that is meant to run it.
 */

const OUT = join(import.meta.dir, '..', 'out');
const SITE = 'https://mrdemonwolf.github.io/wolfwave';
/** Google truncates snippets to the device width; ~160 characters is the practical ceiling. */
const MAX_DESCRIPTION = 160;
const MIN_DESCRIPTION = 50;
const MAX_TITLE = 65;
/** Rich-result types Google retired; emitting them is dead weight. */
const RETIRED_TYPES = new Set(['HowTo']);

const hasBuild = existsSync(join(OUT, 'index.html'));
if (!hasBuild && process.env.CI) {
  throw new Error('apps/docs/out is missing. Build the docs before running the SEO guard.');
}

/** Every exported `index.html` page (the route pages), plus the 404. */
function htmlPages(dir: string): string[] {
  const found: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (name === '_next' || name === 'og' || name === 'api') continue;
    if (statSync(full).isDirectory()) found.push(...htmlPages(full));
    else if (name === 'index.html') found.push(full);
  }
  return found;
}

const decode = (s: string) =>
  s
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>');

function meta(head: string, attr: 'name' | 'property', key: string): string | undefined {
  const m = head.match(new RegExp(`<meta ${attr}="${key}" content="([^"]*)"`));
  return m ? decode(m[1]) : undefined;
}

function jsonLdTypes(html: string): string[] {
  const types: string[] = [];
  for (const m of html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)) {
    const data = JSON.parse(m[1]); // throws (fails the test) on invalid JSON
    expect(data['@context']).toBe('https://schema.org');
    const nodes = Array.isArray(data['@graph']) ? data['@graph'] : [data];
    for (const node of nodes) types.push(String(node['@type']));
  }
  return types;
}

describe.skipIf(!hasBuild)('built pages', () => {
  const pages = hasBuild ? htmlPages(OUT) : [];
  const indexable = pages.filter((p) => !/\/(404|_not-found)\//.test(p) && !readFileSync(p, 'utf8').match(/<meta name="robots" content="[^"]*noindex/));

  test('the build has the pages we expect', () => {
    const routes = indexable.map((p) => `/${relative(OUT, p).replace(/index\.html$/, '')}`);
    for (const route of ['/', '/download/', '/changelog/', '/design-system/', '/docs/', '/docs/installation/', '/docs/bot-commands/']) {
      expect(routes).toContain(route);
    }
  });

  const homeTwitterTitle = hasBuild
    ? meta(readFileSync(join(OUT, 'index.html'), 'utf8'), 'name', 'twitter:title')
    : undefined;
  const titles = new Map<string, string>();
  const descriptions = new Map<string, string>();

  for (const file of indexable) {
    const route = `/${relative(OUT, file).replace(/index\.html$/, '')}`;
    test(`${route} has sound SEO basics`, () => {
      const html = readFileSync(file, 'utf8');
      const head = html.split('</head>')[0];

      expect(html).toMatch(/<html[^>]* lang="en"/);

      const title = decode(head.match(/<title>([^<]*)<\/title>/)?.[1] ?? '');
      expect(title.length).toBeGreaterThan(0);
      expect(title.length).toBeLessThanOrEqual(MAX_TITLE);
      // One brand mention: never "WolfWave … | WolfWave".
      expect(title.match(/WolfWave/g)?.length ?? 0).toBeLessThanOrEqual(1);
      expect(titles.has(title) ? `${title} (also on ${titles.get(title)})` : 'unique').toBe('unique');
      titles.set(title, route);

      const description = meta(head, 'name', 'description') ?? '';
      expect(description.length).toBeGreaterThanOrEqual(MIN_DESCRIPTION);
      expect(description.length).toBeLessThanOrEqual(MAX_DESCRIPTION);
      expect(descriptions.has(description) ? `duplicate of ${descriptions.get(description)}` : 'unique').toBe(
        'unique',
      );
      descriptions.set(description, route);

      // Canonical is absolute, trailing-slashed, and names this very page.
      const canonical = head.match(/<link rel="canonical" href="([^"]*)"/)?.[1];
      expect(canonical).toBe(`${SITE}${route}`);
      expect(meta(head, 'property', 'og:url')).toBe(canonical);
      expect(meta(head, 'name', 'robots') ?? '').not.toContain('noindex');

      // Social cards: an absolute 1200x630 image plus page-specific titles.
      const ogImage = meta(head, 'property', 'og:image') ?? '';
      expect(ogImage.startsWith(`${SITE}/`)).toBe(true);
      expect(meta(head, 'property', 'og:image:width')).toBe('1200');
      expect(meta(head, 'property', 'og:image:height')).toBe('630');
      expect((meta(head, 'property', 'og:image:alt') ?? '').length).toBeGreaterThan(0);
      expect((meta(head, 'property', 'og:title') ?? '').length).toBeGreaterThan(0);
      expect(meta(head, 'name', 'twitter:card')).toBe('summary_large_image');
      expect((meta(head, 'name', 'twitter:image') ?? '').startsWith(`${SITE}/`)).toBe(true);
      // A partial `openGraph`/`twitter` object silently inherits the homepage's card.
      if (route !== '/') expect(meta(head, 'name', 'twitter:title')).not.toBe(homeTwitterTitle);

      // Exactly one <h1>, and every <img> carries alt text (empty is fine for decoration).
      expect(html.match(/<h1[\s>]/g)?.length ?? 0).toBe(1);
      for (const img of html.match(/<img\b[^>]*>/g) ?? []) expect(img).toContain(' alt=');

      // Valid JSON-LD with the types each kind of page should carry.
      const types = jsonLdTypes(html);
      for (const t of types) expect(RETIRED_TYPES.has(t)).toBe(false);
      if (route.startsWith('/docs/')) {
        expect(types).toContain('TechArticle');
        expect(types).toContain('BreadcrumbList');
        expect(types).not.toContain('SoftwareApplication');
        expect(types).not.toContain('FAQPage');
      }
      if (route === '/') {
        expect(types).toEqual(expect.arrayContaining(['WebSite', 'Organization', 'SoftwareApplication', 'FAQPage']));
      }
      if (route === '/download/') expect(types).toContain('SoftwareApplication');
      if (route === '/changelog/') expect(types).toEqual(expect.arrayContaining(['CollectionPage', 'BreadcrumbList']));
    });
  }

  test('the 404 page is noindex and claims no structured data', () => {
    const html = readFileSync(join(OUT, '404.html'), 'utf8');
    expect(html).toMatch(/<meta name="robots" content="[^"]*noindex/);
    expect(jsonLdTypes(html)).toEqual([]);
  });

  test('the compatibility changelog points search engines to the public release log', () => {
    const html = readFileSync(join(OUT, 'docs/changelog/index.html'), 'utf8');
    expect(meta(html, 'name', 'robots')).toContain('noindex');
    expect(html).toContain(`<link rel="canonical" href="${SITE}/changelog/"`);
  });

  test('draft release headings and notes are absent from public changelog exports', () => {
    const raw = readFileSync(join(import.meta.dir, '../content/docs/changelog.mdx'), 'utf8');
    const draft = raw.match(/^##[^\n]*\bUnreleased\b[^\n]*\n([\s\S]*?)(?=^## |$(?![\s\S]))/m);
    const firstLead = draft?.[1].match(/^- \*\*([^*]+)\*\*/m)?.[1];
    for (const relativePath of ['changelog/index.html', 'docs/changelog/index.html', 'api/search', 'llms-full.txt']) {
      const content = readFileSync(join(OUT, relativePath), 'utf8');
      expect(content).not.toContain(draft?.[0].split('\n')[0] ?? 'IMPOSSIBLE_DRAFT_HEADING');
      if (firstLead) expect(content).not.toContain(firstLead);
    }
  });

  test('the sitemap lists exactly the indexable pages, by canonical URL', () => {
    const xml = readFileSync(join(OUT, 'sitemap.xml'), 'utf8');
    const locs = [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]).sort();
    const expected = indexable.map((p) => `${SITE}/${relative(OUT, p).replace(/index\.html$/, '')}`).sort();
    expect(locs).toEqual(expected);
  });

  test('robots.txt points at the sitemap', () => {
    expect(readFileSync(join(OUT, 'robots.txt'), 'utf8')).toContain(`Sitemap: ${SITE}/sitemap.xml`);
  });

  test('llms.txt follows the llmstxt.org shape', () => {
    const txt = readFileSync(join(OUT, 'llms.txt'), 'utf8');
    expect(txt.startsWith('# WolfWave\n')).toBe(true);
    expect(txt).toMatch(/\n> \S/);
    expect(txt).toContain(`${SITE}/docs/installation/`);
  });
});
