import type { MetadataRoute } from "next";
import { basePath, siteUrl } from "@/lib/site";

export const dynamic = "force-static";
export const revalidate = false;

/**
 * Crawl rules. Paths carry the base path (`/wolfwave` in production) because
 * the export lives under it; a bare `/api/` would never match a real URL.
 *
 * GitHub Pages serves a project site under the owner's domain, so crawlers
 * only honor a robots.txt at the domain root, not this one. It still ships so
 * the rules are right the day the site moves to its own domain, and the
 * sitemap should be submitted directly in Google Search Console and Bing
 * Webmaster Tools (`${siteUrl}/sitemap.xml`) rather than discovered here.
 */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [
      {
        userAgent: "*",
        allow: `${basePath}/`,
        disallow: [`${basePath}/api/`, `${basePath}/og/`],
      },
    ],
    sitemap: `${siteUrl}/sitemap.xml`,
  };
}
