import type { Metadata } from "next";
import Link from "next/link";
import {
  ArrowRight,
  Download,
  Terminal,
} from "lucide-react";
import { GithubIcon } from "@/components/icons";
import {
  absoluteUrl,
  getLatestDmgUrl,
  getLatestVersion,
  homepageSeo,
  pageUrl,
  repoUrl,
} from "@/lib/site";
import { downloadGraphLd, jsonLdScript } from "@/lib/seo";
import { SendToMac } from "../_widgets/SendToMac";
import { CopyButton } from "./copy-button";

// ── Constants ────────────────────────────────────────────────
const REPO_URL = repoUrl;
const BREW_CMD = "brew tap mrdemonwolf/den\nbrew install --cask wolfwave";

const SOCIAL_TITLE = "Download WolfWave: Free for macOS 26+";
const SOCIAL_DESCRIPTION =
  "Free Mac app for Apple Music streamers. Twitch chat, Discord Rich Presence, and an OBS overlay. Signed DMG or Homebrew. Apple Silicon.";
const SOCIAL_IMAGE = {
  url: absoluteUrl("/opengraph-image.png"),
  width: 1200,
  height: 630,
  alt: homepageSeo.ogImageAlt,
};

// `title.absolute`: the string already names WolfWave, so the root
// "%s | WolfWave" template would brand it twice. `openGraph` and `twitter` are
// spelled out in full: Next replaces (does not merge) these objects, so a
// partial `openGraph` here dropped the card image and the page inherited the
// homepage's Twitter title.
export const metadata: Metadata = {
  title: { absolute: "Download WolfWave: Free for macOS 26+ (DMG or Homebrew)" },
  description:
    "Download WolfWave free for macOS 26+ on Apple Silicon. Get the signed .dmg or install with Homebrew. Needs the Apple Music app. Free and open source.",
  keywords: [
    "download wolfwave",
    "wolfwave dmg",
    "brew install wolfwave",
    "brew tap mrdemonwolf/den",
    "apple music twitch bot download",
    "free macos streamer app",
  ],
  alternates: { canonical: pageUrl("/download") },
  openGraph: {
    type: "website",
    url: pageUrl("/download"),
    siteName: "WolfWave",
    title: SOCIAL_TITLE,
    description: SOCIAL_DESCRIPTION,
    images: [SOCIAL_IMAGE],
  },
  twitter: {
    card: "summary_large_image",
    site: "@mrdemonwolf",
    creator: "@mrdemonwolf",
    title: SOCIAL_TITLE,
    description: SOCIAL_DESCRIPTION,
    images: [SOCIAL_IMAGE.url],
  },
};

/** Download page: latest DMG (resolved at build time) plus the Homebrew command. */
export default async function DownloadPage() {
  const [downloadUrl, version] = await Promise.all([getLatestDmgUrl(), getLatestVersion()]);

  return (
    <main id="nd-page" tabIndex={-1} className="ww-font ww-bg-base">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLdScript(downloadGraphLd(version, downloadUrl)) }}
      />
      {/* ═══════════════ HERO ═══════════════ */}
      <section className="relative overflow-hidden">
        <div className="ww-hero-glow" aria-hidden="true" />
        <div className="relative z-10 px-[10%] md:px-6 pt-20 pb-12 sm:pt-28">
          <div className="mx-auto max-w-3xl text-center">
            <span
              className="ww-reveal ww-reveal-1 ww-pill"
              style={{
                backgroundColor: "var(--brand-50)",
                color: "var(--brand-600)",
              }}
            >
              macOS 26+ · Apple Silicon · Apple Music
            </span>
            <h1 className="ww-reveal ww-reveal-1 ww-display ww-text-1 text-5xl sm:text-7xl mt-5">
              Download WolfWave
            </h1>
            <p className="ww-reveal ww-reveal-2 ww-text-2 text-lg sm:text-xl mt-5 max-w-md mx-auto leading-relaxed">
              Tiny menu bar app. Install in under a minute.
            </p>

            <div className="ww-reveal ww-reveal-3 mt-8 flex flex-col sm:flex-row items-center justify-center gap-3">
              <a
                href={downloadUrl}
                className="ww-btn ww-btn-primary ww-btn-lg ww-cta-desktop"
              >
                <Download className="w-4 h-4" aria-hidden="true" />
                Download .dmg
              </a>
              <SendToMac
                url={pageUrl("/download")}
                className="ww-btn ww-btn-primary ww-btn-lg ww-cta-phone"
              />
              <a
                href={REPO_URL}
                target="_blank"
                rel="noopener noreferrer"
                className="ww-btn ww-btn-ghost ww-btn-lg"
              >
                <GithubIcon className="w-4 h-4" aria-hidden="true" />
                View on GitHub
              </a>
            </div>

            <p className="mt-4 text-sm ww-text-2 ww-phone-only">
              WolfWave installs on a Mac. Send yourself the link.
            </p>

            <p className="mt-6 text-sm ww-text-2">
              Free · Open source · Signed and notarized by Apple
            </p>
          </div>
        </div>
      </section>

      {/* ═══════════════ INSTALL METHODS ═══════════════ */}
      <section className="ww-bg-base px-[10%] md:px-6 pb-16">
        <div className="mx-auto max-w-5xl">
          <div className="grid md:grid-cols-2 gap-5 items-stretch">
            {/* DMG */}
            <div
              className="ww-card ww-bg-surface flex flex-col h-full"
              style={{ border: "1px solid var(--hairline)" }}
            >
              <div className="flex items-center justify-between gap-3 mb-5">
                <div
                  className="w-11 h-11 rounded-xl inline-flex items-center justify-center"
                  style={{
                    backgroundColor: "var(--brand-50)",
                    color: "var(--brand-500)",
                  }}
                >
                  <Download className="w-5 h-5" />
                </div>
                <span
                  className="ww-pill"
                  style={{
                    backgroundColor: "var(--brand-50)",
                    color: "var(--brand-600)",
                  }}
                >
                  Recommended
                </span>
              </div>
              <h2 className="ww-display ww-text-1 text-xl mb-2">
                DMG installer
              </h2>
              <p className="ww-text-2 text-base leading-relaxed flex-1">
                Drag to Applications. Auto-updates via Sparkle.
              </p>
              <a
                href={downloadUrl}
                className="ww-btn ww-btn-primary mt-6"
              >
                <Download className="w-4 h-4" />
                Download .dmg
              </a>
            </div>

            {/* Homebrew */}
            <div
              className="ww-card ww-bg-surface flex flex-col h-full"
              style={{ border: "1px solid var(--hairline)" }}
            >
              <div className="flex items-center justify-between gap-3 mb-5">
                <div
                  className="w-11 h-11 rounded-xl inline-flex items-center justify-center"
                  style={{
                    backgroundColor: "var(--bg-base)",
                    color: "var(--txt-1)",
                    border: "1px solid var(--hairline)",
                  }}
                >
                  <Terminal className="w-5 h-5" />
                </div>
                <span className="ww-pill">Homebrew</span>
              </div>
              <h2 className="ww-display ww-text-1 text-xl mb-2">
                Command line
              </h2>
              <p className="ww-text-2 text-base leading-relaxed mb-4">
                Auto-updates via <code className="ww-mono ww-text-1 whitespace-nowrap">brew upgrade --cask</code>.
              </p>
              <pre
                className="ww-code flex-1"
                style={{ margin: 0 }}
              >{BREW_CMD}</pre>
              <div className="mt-4 flex justify-end">
                <CopyButton value={BREW_CMD} label="Copy command" />
              </div>
            </div>
          </div>

          {/* ═══════════════ TRUST + REQUIREMENTS ═══════════════ */}
          <div className="mt-12 flex flex-wrap items-center justify-center gap-2">
            {["Notarized", "Sandboxed", "Keychain", "No telemetry", "GPL-3.0"].map(
              (label) => (
                <span key={label} className="ww-pill">
                  {label}
                </span>
              ),
            )}
          </div>
          <p className="ww-text-2 text-sm text-center mt-4 max-w-xl mx-auto">
            Requires macOS 26 Tahoe, Apple Silicon, and the Apple Music app. Intel Macs and Spotify are not supported.
          </p>

          <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
            <Link href="/docs/installation" className="ww-btn ww-btn-ghost">
              Installation guide
              <ArrowRight className="w-3.5 h-3.5" />
            </Link>
            <Link href="/docs/features" className="ww-btn ww-btn-ghost">
              Usage guide
              <ArrowRight className="w-3.5 h-3.5" />
            </Link>
          </div>
        </div>
      </section>
    </main>
  );
}
