import type { MetadataRoute } from "next";
import { getLatestRelease, pageUrl } from "@/lib/site";
import { source } from "@/lib/source";
import { lastCommitDate } from "@/lib/seo";

export const dynamic = "force-static";
export const revalidate = false;

// Submit `${siteUrl}/sitemap.xml` in Google Search Console and Bing Webmaster
// Tools after a deploy that adds or removes pages. On GitHub Pages the robots.txt
// that points here is not read (it is not at the domain root), so a direct
// submission is the only reliable way crawlers learn about it.

type Freq = MetadataRoute.Sitemap[number]["changeFrequency"];

/** Maps a URL path to sitemap priority and change frequency; legal pages rank lowest, home/docs/changelog highest. */
function classify(url: string): { priority: number; changeFrequency: Freq } {
  if (url === "/") return { priority: 1.0, changeFrequency: "monthly" };
  if (url === "/docs" || url === "/docs/") return { priority: 0.9, changeFrequency: "weekly" };
  if (url.includes("/changelog")) return { priority: 0.9, changeFrequency: "weekly" };
  if (url.includes("/privacy-policy") || url.includes("/terms-of-service")) {
    return { priority: 0.5, changeFrequency: "monthly" };
  }
  return { priority: 0.7, changeFrequency: "weekly" };
}

/** Spreads to nothing when the date is unknown, so the entry omits `lastModified` instead of lying. */
function withDate(date: Date | undefined): { lastModified?: Date } {
  return date ? { lastModified: date } : {};
}

/**
 * Sitemap for the static export: home, download, and every docs page, each at
 * the exact URL its canonical names. `llms.txt` / `llms-full.txt` are left out
 * on purpose: they are plain-text files for AI tools, not pages for search
 * results. Google ignores `changefreq` and `priority` (and uses `lastmod` only
 * when it is accurate, which is why it comes from git); they stay for other
 * crawlers that read them.
 */
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  // The landing and download pages change meaningfully when a release ships
  // (new DMG link, new version), so they carry the release date. Fall back to
  // the page source's own last commit when GitHub is unreachable at build time.
  const release = await getLatestRelease();
  const releaseDate = release?.publishedAt ? new Date(release.publishedAt) : undefined;

  const staticEntries: MetadataRoute.Sitemap = [
    {
      url: pageUrl("/"),
      ...withDate(releaseDate ?? lastCommitDate("app/(home)/page.tsx")),
      ...classify("/"),
    },
    {
      // Conversion page + the nav's Download target. It's a (home) route, not a
      // docs page, so source.getPages() misses it. List it explicitly.
      url: pageUrl("/download"),
      ...withDate(releaseDate ?? lastCommitDate("app/(home)/download/page.tsx")),
      priority: 0.9,
      changeFrequency: "monthly",
    },
  ];

  const docEntries: MetadataRoute.Sitemap = source.getPages().map((page) => ({
    url: pageUrl(page.url),
    ...withDate(lastCommitDate((page as { absolutePath?: string }).absolutePath)),
    ...classify(page.url),
  }));

  return [...staticEntries, ...docEntries];
}
