/** Canonical production origin plus project path. Used for absolute URLs; it does not follow `NEXT_PUBLIC_BASE_PATH`. */
export const siteUrl = "https://mrdemonwolf.github.io/wolfwave";

/**
 * Canonical GitHub URLs. Single source of truth so the homepage links and the
 * JSON-LD `url` fields never drift on casing. GitHub redirects on casing, but
 * structured-data consumers compare strings literally, so keep one spelling.
 */
export const orgUrl = "https://github.com/MrDemonWolf";
export const repoUrl = "https://github.com/MrDemonWolf/WolfWave";

/**
 * Deployment base path for in-site asset and route URLs: `/wolfwave` by default,
 * `""` when `NEXT_PUBLIC_BASE_PATH` is empty or `/`, otherwise the path of the
 * env value (URL or path). Same rules as `next.config.mjs` and `getAssetPath`;
 * keep the three in step.
 */
export const basePath = (() => {
  const envValue = process.env.NEXT_PUBLIC_BASE_PATH;
  if (envValue === undefined) return "/wolfwave";
  if (envValue === "" || envValue === "/") return "";
  let path = envValue;
  try {
    path = new URL(envValue).pathname;
  } catch {}
  if (!path || path === "/") return "";
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return normalized.endsWith("/") ? normalized.slice(0, -1) : normalized;
})();

/**
 * Joins `path` onto the canonical site origin, yielding an absolute URL. Use it
 * for assets and files (`/opengraph-image.png`); pages want {@link pageUrl}.
 */
export function absoluteUrl(path: string): string {
  const clean = path.startsWith("/") ? path : `/${path}`;
  return `${siteUrl}${clean === "/" ? "" : clean}`;
}

/**
 * Absolute URL for a page route, with the trailing slash the static export
 * actually serves (`trailingSlash: true`). Canonicals, og:url, JSON-LD, and the
 * sitemap all go through this so a page never advertises two spellings of
 * itself. `pageUrl("/")` is `${siteUrl}/`; `pageUrl("/download")` is
 * `${siteUrl}/download/`.
 */
export function pageUrl(path: string): string {
  const lead = path.startsWith("/") ? path : `/${path}`;
  const clean = lead.endsWith("/") ? lead : `${lead}/`;
  return `${siteUrl}${clean}`;
}

const API_REPO = repoUrl.replace("https://github.com", "https://api.github.com/repos");
const GITHUB_HEADERS = {
  Accept: "application/vnd.github+json",
  "User-Agent": "wolfwave-docs",
} as const;

/** The newest stable GitHub release, as resolved at build time. */
export interface LatestRelease {
  /** Bare SemVer, e.g. `2.1.0`. */
  version: string;
  /** ISO-8601 publish time, or null when GitHub omitted it. */
  publishedAt: string | null;
}

/**
 * Build-time fetch of the latest GitHub release. Returns `null` on any failure
 * (rate limit, offline, no releases) so callers drop the field rather than ship
 * a stale hardcoded version. The static export bakes the result in per deploy.
 */
export async function getLatestRelease(): Promise<LatestRelease | null> {
  try {
    const res = await fetch(`${API_REPO}/releases/latest`, {
      headers: GITHUB_HEADERS,
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) return null;
    const rel = await res.json();
    if (typeof rel?.tag_name !== "string") return null;
    const version = rel.tag_name.replace(/^v/, "");
    if (!version) return null;
    const publishedAt = typeof rel.published_at === "string" ? rel.published_at : null;
    return { version, publishedAt };
  } catch {
    return null;
  }
}

/** Bare SemVer of the latest release (e.g. `2.1.0`), or `null` on failure. */
export async function getLatestVersion(): Promise<string | null> {
  return (await getLatestRelease())?.version ?? null;
}

/**
 * The star count earns a landing-page chip only at or above this. A small real
 * number reads as weak proof next to "Signed & notarized", so below it the chip
 * stays hidden instead of being padded or invented.
 */
export const STAR_CHIP_MIN = 50;

/**
 * Build-time GitHub star count for the repo. Returns `null` on any failure so
 * the landing page simply omits the chip; never a cached or invented number.
 */
export async function getRepoStars(): Promise<number | null> {
  try {
    const res = await fetch(API_REPO, {
      headers: GITHUB_HEADERS,
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) return null;
    const repo = await res.json();
    return typeof repo?.stargazers_count === "number" ? repo.stargazers_count : null;
  } catch {
    return null;
  }
}

/**
 * Direct link to the latest stable macOS installer. The release workflow
 * publishes versioned DMGs; fall back to the release page if GitHub is
 * unavailable during the static site build.
 */
export async function getLatestDmgUrl(): Promise<string> {
  const version = await getLatestVersion();
  if (!version) return `${repoUrl}/releases/latest`;
  return `${repoUrl}/releases/download/v${version}/WolfWave-${version}.dmg`;
}

/**
 * Single source of truth for the homepage / root SEO + social-card copy.
 *
 * Every homepage-facing surface reads from this object so the page metadata,
 * the OG image, and the Twitter image can never drift apart:
 *  - `app/layout.tsx`        root `<title>`, openGraph, twitter, JSON-LD
 *  - `app/(home)/page.tsx`   homepage route metadata
 *  - `app/opengraph-image.tsx` + `app/twitter-image.tsx`  the social card
 *
 * Change the homepage pitch here once and all of the above update on the next
 * build. Per-page docs OG cards are driven separately by each MDX file's
 * frontmatter (see `app/og/docs/[...slug]/route.tsx`).
 */
export const homepageSeo = {
  /** Browser `<title>` and og/twitter title. Keep the keyword-rich phrasing. */
  title: "WolfWave. Free Apple Music to Twitch, Discord & OBS on Mac",

  /** Full meta description used for search snippets. Kept under ~160 chars so
   *  Google does not truncate it. */
  description:
    "Free Mac menu bar app built for Apple Music, not Spotify. Hit play and your Twitch chat, Discord Rich Presence, and OBS overlay stay in sync.",

  /** Shorter description for the social cards (og + twitter). */
  socialDescription:
    "Built for Apple Music, not Spotify. Hit play and your Twitch chat, Discord profile, and OBS overlay keep themselves in sync.",

  /** OG card eyebrow pill. */
  ogEyebrow: "Free & open source · macOS 26+",

  /** OG card headline. `ogAccentWord` is the substring rendered in brand blue. */
  ogTitle: "Apple Music, finally on your stream.",
  ogAccentWord: "on your stream.",

  /** OG card supporting line. Kept short so it lands in ~2 lines on the card. */
  ogCardDescription:
    "A tiny Mac menu bar app. Press play once. Twitch, Discord, and OBS keep up on their own.",

  /** OG card chips. Order matters; first chips read first when cropped. */
  ogChips: ["Twitch chat bot", "Discord Rich Presence", "OBS overlay", "Open source"],

  /** Alt text for the OG image. Describe the card, not just the brand. */
  ogImageAlt:
    "WolfWave. Apple Music now playing pushed to Twitch chat, Discord Rich Presence, and an OBS overlay on macOS.",

  /** Homepage SEO keywords (long-tail, Apple-Music-first). */
  keywords: [
    "apple music twitch chat bot mac",
    "apple music discord rich presence mac",
    "apple music obs overlay mac",
    "apple music song requests twitch",
    "free apple music twitch bot",
    "apple music now playing overlay",
    "macos menu bar music streamer",
    "twitch song requests without spotify premium",
    "wolfwave stream deck plugin",
    "elgato stream deck apple music",
  ],
} as const;
