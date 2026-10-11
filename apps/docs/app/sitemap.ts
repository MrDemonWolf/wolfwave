import type { MetadataRoute } from "next";
import { execFileSync } from "node:child_process";
import { getLatestRelease, pageUrl } from "@/lib/site";
import { source } from "@/lib/source";

export const dynamic = "force-static";
export const revalidate = false;

// Submit `${siteUrl}/sitemap.xml` in Google Search Console and Bing Webmaster
// Tools after a deploy that adds or removes pages. On GitHub Pages the robots.txt
// that points here is not read (it is not at the domain root), so a direct
// submission is the only reliable way crawlers learn about it.

type Freq = MetadataRoute.Sitemap[number]["changeFrequency"];

function classify(url: string): { priority: number; changeFrequency: Freq } {
  if (url === "/") return { priority: 1.0, changeFrequency: "monthly" };
  if (url === "/docs" || url === "/docs/") return { priority: 0.9, changeFrequency: "weekly" };
  if (url.includes("/changelog")) return { priority: 0.9, changeFrequency: "weekly" };
  if (url.includes("/privacy-policy") || url.includes("/terms-of-service")) {
    return { priority: 0.5, changeFrequency: "monthly" };
  }
  return { priority: 0.7, changeFrequency: "weekly" };
}

/**
 * Last commit that touched `filePath`, from git. File mtimes are useless here:
 * a CI checkout stamps every file with the checkout time, so they would all
 * claim "modified today". Returns undefined (and the entry omits lastModified)
 * when git is unavailable or the file is untracked, rather than guessing.
 */
function lastCommitDate(filePath: string | undefined): Date | undefined {
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

function withDate(date: Date | undefined): { lastModified?: Date } {
  return date ? { lastModified: date } : {};
}

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
