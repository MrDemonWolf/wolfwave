import { createMDX } from "fumadocs-mdx/next";

// Static export for GitHub Pages; basePath logic mirrors `getAssetPath` in lib/utils.ts.
const withMDX = createMDX();
// Resolve basePath: default to the custom domain root, including local dev.
// NEXT_PUBLIC_BASE_PATH can override this for deployments under a subpath.
const basePath = (() => {
  const envValue = process.env.NEXT_PUBLIC_BASE_PATH;
  if (envValue === undefined) return "";
  if (envValue === "" || envValue === "/") return "";
  let path = envValue;
  try {
    path = new URL(envValue).pathname;
  } catch {
    // not a URL; treat as path string
  }
  if (!path || path === "/") return "";
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return normalized.endsWith("/") ? normalized.slice(0, -1) : normalized;
})();

/** @type {import('next').NextConfig} */
const config = {
  output: "export",
  reactStrictMode: true,
  trailingSlash: true,
  basePath: basePath || undefined,
  assetPrefix: basePath ? `${basePath}/` : undefined,
};

export default withMDX(config);
