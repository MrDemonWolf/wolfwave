"use client";

import { useEffect } from "react";

/**
 * Old docs slugs that were merged away in the 2026-08 docs restructure, mapped
 * to their new homes. GitHub Pages serves the exported 404.html at the original
 * URL, so this client effect can forward a stale link before the visitor reads
 * the not-found copy.
 */
const MOVED: Record<string, string> = {
  "/docs/usage": "/docs/features",
  "/docs/getting-started": "/docs/development",
  "/docs/appearance": "/docs/settings",
};

/**
 * Renders nothing; on mount, forwards a moved docs URL (keeping the hash) to
 * its new location. Unknown paths are left alone so the 404 page shows.
 */
export function NotFoundRedirect() {
  useEffect(() => {
    const { pathname, hash } = window.location;
    // basePath is "/wolfwave" in production, "" in dev.
    const base = pathname.startsWith("/wolfwave") ? "/wolfwave" : "";
    const path = pathname.slice(base.length).replace(/\/$/, "");
    const target = MOVED[path];
    if (target) {
      window.location.replace(`${base}${target}/${hash}`);
    }
  }, []);

  return null;
}
