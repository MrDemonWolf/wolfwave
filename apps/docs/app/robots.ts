import type { MetadataRoute } from "next";
import { basePath, siteUrl } from "@/lib/site";

export const dynamic = "force-static";
export const revalidate = false;

/**
 * Root-level crawl rules for the custom domain. An optional deployment base
 * path is kept in the rules for alternate previews. The sitemap uses the
 * canonical production origin.
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
