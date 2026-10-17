import { execFileSync } from "node:child_process";
import { USER_THEMES, WIDGET_LAYOUTS } from "@/app/(home)/_widgets/widget-themes.generated";
import { absoluteUrl, homepageSeo, orgUrl, pageUrl, repoUrl } from "./site";

/**
 * Shared SEO helpers: page titles, git-derived modified dates, and the
 * schema.org JSON-LD the site emits.
 *
 * What the site emits, and why (checked against Google's docs in 2026-10):
 *  - Home: `WebSite` + `Organization` + `SoftwareApplication` (one `@graph`)
 *    and a `FAQPage` built from the visible landing FAQ (`lib/faq.tsx`).
 *  - Download: the same `SoftwareApplication` node, by `@id`.
 *  - Docs pages: `TechArticle` + `BreadcrumbList`.
 *
 * Deliberately NOT emitted: `HowTo` (Google retired HowTo rich results) and
 * per-page `FAQPage` blocks whose questions are not visible on the page
 * (structured data must describe what the reader can see). Google also stopped
 * showing FAQ rich results in 2026; the landing FAQPage stays because it is
 * valid, matches the visible FAQ, and other consumers (Bing, AI assistants)
 * still read it. The SoftwareApplication node has no rating or review, so it
 * is not eligible for Google's software rich result; we never invent one.
 */

/** Organization that publishes WolfWave. One `@id` so every page points at the same entity. */
export const ORG_ID = `${pageUrl("/")}#organization`;
/** The app entity's `@id`, shared by the homepage and the download page. */
export const APP_ID = `${pageUrl("/")}#app`;
/** The site entity's `@id`. */
export const WEBSITE_ID = `${pageUrl("/")}#website`;

/**
 * `<title>` for a docs page. The root layout appends ` | WolfWave`, so a
 * title that already names WolfWave goes out as `absolute` to avoid
 * "WolfWave vs. … | WolfWave".
 */
export function docsTitle(title: string): string | { absolute: string } {
  return /wolfwave/i.test(title) ? { absolute: title } : title;
}

/**
 * Last commit that touched `filePath`, from git. File mtimes are useless here:
 * a CI checkout stamps every file with the checkout time, so they would all
 * claim "modified today". Returns undefined when git is unavailable or the file
 * is untracked, so callers omit the date rather than guess.
 */
export function lastCommitDate(filePath: string | undefined): Date | undefined {
  if (!filePath) return undefined;
  try {
    const out = execFileSync("git", ["log", "-1", "--format=%cI", "--", filePath], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!out) return undefined;
    const date = new Date(out);
    return Number.isNaN(date.getTime()) ? undefined : date;
  } catch {
    return undefined;
  }
}

const organization = {
  "@type": "Organization",
  "@id": ORG_ID,
  name: "MrDemonWolf, Inc.",
  url: "https://www.mrdemonwolf.com",
  logo: absoluteUrl("/icon.png"),
  sameAs: [orgUrl],
};

/**
 * schema.org `SoftwareApplication` for WolfWave.
 * @param version latest release version, or null to omit `softwareVersion`.
 * @param downloadUrl direct DMG link from `getLatestDmgUrl()`.
 */
export function softwareApplicationLd(version: string | null, downloadUrl: string) {
  return {
    "@type": "SoftwareApplication",
    "@id": APP_ID,
    name: "WolfWave",
    description: homepageSeo.description,
    operatingSystem: "macOS 26 or later",
    applicationCategory: "MultimediaApplication",
    applicationSubCategory: "Live streaming",
    processorRequirements: "Apple Silicon",
    isAccessibleForFree: true,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    author: { "@id": ORG_ID },
    publisher: { "@id": ORG_ID },
    url: pageUrl("/"),
    downloadUrl,
    installUrl: pageUrl("/download"),
    // From the latest GitHub release at build time; omitted when the fetch
    // fails so a stale hardcoded version never ships.
    ...(version ? { softwareVersion: version } : {}),
    releaseNotes: pageUrl("/docs/changelog"),
    image: absoluteUrl("/icon.png"),
    screenshot: absoluteUrl("/opengraph-image.png"),
    featureList: [
      "Apple Music now playing in Twitch chat (!song, !last)",
      "Twitch song requests for Apple Music (!sr), channel points, and Bits",
      "Discord Rich Presence with Apple Music album art",
      `OBS browser-source overlay with ${USER_THEMES.length} themes and ${Object.keys(WIDGET_LAYOUTS).length} layouts`,
      "Optional Elgato Stream Deck plugin",
      "Vote to skip from chat or Twitch Polls",
    ],
    license: `${repoUrl}/blob/main/LICENSE`,
    codeRepository: repoUrl,
  };
}

/** Homepage graph: the site, its publisher, and the app. */
export function homeGraphLd(version: string | null, downloadUrl: string) {
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "WebSite",
        "@id": WEBSITE_ID,
        name: "WolfWave",
        url: pageUrl("/"),
        inLanguage: "en-US",
        publisher: { "@id": ORG_ID },
      },
      organization,
      softwareApplicationLd(version, downloadUrl),
    ],
  };
}

/** Download page graph: the app plus its publisher, so `@id` references resolve on the page. */
export function downloadGraphLd(version: string | null, downloadUrl: string) {
  return {
    "@context": "https://schema.org",
    "@graph": [organization, softwareApplicationLd(version, downloadUrl)],
  };
}

/** Docs page graph: `TechArticle` + a Home › Docs › Page `BreadcrumbList`. */
export function docsPageLd(opts: {
  url: string;
  title: string;
  description?: string;
  dateModified?: Date;
  isDocsRoot: boolean;
}) {
  const crumbs = [
    { name: "Home", item: pageUrl("/") },
    { name: "Docs", item: pageUrl("/docs") },
    ...(opts.isDocsRoot ? [] : [{ name: opts.title, item: opts.url }]),
  ];
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "TechArticle",
        headline: opts.title,
        ...(opts.description ? { description: opts.description } : {}),
        inLanguage: "en-US",
        url: opts.url,
        mainEntityOfPage: opts.url,
        ...(opts.dateModified ? { dateModified: opts.dateModified.toISOString() } : {}),
        isPartOf: { "@type": "WebSite", "@id": WEBSITE_ID, name: "WolfWave", url: pageUrl("/") },
        about: { "@id": APP_ID },
        author: { "@type": "Organization", "@id": ORG_ID, name: "MrDemonWolf, Inc." },
        publisher: { "@type": "Organization", "@id": ORG_ID, name: "MrDemonWolf, Inc." },
      },
      {
        "@type": "BreadcrumbList",
        itemListElement: crumbs.map((c, i) => ({
          "@type": "ListItem",
          position: i + 1,
          name: c.name,
          item: c.item,
        })),
      },
    ],
  };
}

/** Serializes JSON-LD for a `<script>` body, escaping `<` so a string can never close the tag. */
export function jsonLdScript(data: unknown): string {
  return JSON.stringify(data).replace(/</g, "\\u003c");
}
