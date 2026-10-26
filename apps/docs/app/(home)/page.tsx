import type { Metadata } from "next";
import Link from "next/link";
import {
  absoluteUrl,
  getLatestDmgUrl,
  getLatestRelease,
  homepageSeo,
  pageUrl,
} from "@/lib/site";
import { buildFaqJsonLd, landingFaq } from "@/lib/faq";
import { homeGraphLd, jsonLdScript } from "@/lib/seo";
import { ArrowRight, Check, Download, MessageSquareText, Music, X as XIcon } from "lucide-react";
import { TwitchIcon } from "@/components/icons";
import { OBSOverlayWidget } from "./_widgets/OBSOverlayWidget";
import { SendToMac } from "./_widgets/SendToMac";
import { HeroPlayer } from "./_widgets/HeroPlayer";
import { ScrollMotion } from "./_widgets/ScrollMotion";

const DISCORD_URL = "https://mrdwolf.net/discord";

// Homepage SEO is centralized in `homepageSeo` (lib/site.ts) so the page meta,
// the OG image, and the Twitter image always tell the same story.
// `title.absolute` skips the root "%s | WolfWave" template; the homepage title
// already leads with the brand, so the template would print it twice.
export const metadata: Metadata = {
  title: { absolute: homepageSeo.title },
  description: homepageSeo.description,
  keywords: [...homepageSeo.keywords],
  alternates: { canonical: pageUrl("/") },
  openGraph: {
    type: "website",
    url: pageUrl("/"),
    siteName: "WolfWave",
    title: homepageSeo.title,
    description: homepageSeo.socialDescription,
    images: [
      {
        url: absoluteUrl("/opengraph-image.png"),
        width: 1200,
        height: 630,
        alt: homepageSeo.ogImageAlt,
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    site: "@mrdemonwolf",
    creator: "@mrdemonwolf",
    title: homepageSeo.title,
    description: homepageSeo.socialDescription,
    images: [absoluteUrl("/opengraph-image.png")],
  },
};

// ── Section kicker ───────────────────────────────────────────
// One numbered anchor tag, shared by every section, so the whole page
// reads with a single consistent spine: 01 · Who it's for, 02 · Song requests …
function Kicker({
  index,
  children,
}: {
  index: string;
  children: React.ReactNode;
}) {
  return (
    <span className="ww-kicker">
      <span className="ww-kicker-num">{index}</span>
      {children}
    </span>
  );
}

// ── Centered section heading (kicker + title + sub) ──────────
function CenterHead({
  index,
  kicker,
  title,
  sub,
}: {
  index: string;
  kicker: string;
  title: React.ReactNode;
  sub?: React.ReactNode;
}) {
  return (
    <div data-scroll-reveal className="max-w-3xl mx-auto text-center">
      <div className="flex justify-center mb-5">
        <Kicker index={index}>{kicker}</Kicker>
      </div>
      <h2 className="ww-display ww-text-1 text-4xl sm:text-5xl lg:text-6xl">
        {title}
      </h2>
      {sub ? (
        <p className="ww-text-2 text-lg sm:text-xl mt-5 leading-relaxed">
          {sub}
        </p>
      ) : null}
    </div>
  );
}

// ── Demo caption ─────────────────────────────────────────────
// Every simulated widget says so in plain sight, so invented chat and songs
// can never be read as real viewers or real social proof.
function DemoCaption({
  children,
  as: Tag = "p",
}: {
  children: React.ReactNode;
  as?: "p" | "figcaption";
}) {
  return <Tag className="ww-demo-caption">{children}</Tag>;
}

// ── FAQ row (native details/summary, token-styled) ───────────
function FaqRow({ q, a }: { q: string; a: React.ReactNode }) {
  return (
    <details className="group ww-faq">
      <summary
        className="cursor-pointer list-none flex items-center justify-between gap-4"
        style={{ fontWeight: 600 }}
      >
        <span className="ww-text-1 text-base sm:text-lg">{q}</span>
        <span
          className="ww-text-brand text-2xl leading-none transition-transform group-open:rotate-45"
          aria-hidden="true"
        >
          +
        </span>
      </summary>
      <div className="ww-faq-body ww-text-2 text-base leading-relaxed">{a}</div>
    </details>
  );
}

/** Landing page. Section ids are linked from the navbar; keep them stable (see CLAUDE.md). */
export default async function HomePage() {
  const [downloadUrl, release] = await Promise.all([
    getLatestDmgUrl(),
    getLatestRelease(),
  ]);
  const downloadPageUrl = pageUrl("/download");
  const faqJsonLd = buildFaqJsonLd();
  const siteJsonLd = homeGraphLd(release?.version ?? null, downloadUrl);

  return (
    <main id="nd-page" tabIndex={-1} className="ww-font ww-bg-base">
      <ScrollMotion />
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLdScript(siteJsonLd) }}
      />
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLdScript(faqJsonLd) }}
      />
      <section className="ww-broadcast-hero relative overflow-hidden">
        <div className="ww-home-hero">
          <div className="ww-hero-copy">
            <h1 className="ww-reveal ww-reveal-1 ww-hero-headline ww-text-1">
              Apple Music.
              <br />
              <span className="ww-text-brand">Meet your stream.</span>
            </h1>
            <p className="ww-reveal ww-reveal-2 ww-hero-description ww-text-2">
              The free Mac app that puts Apple Music in your Twitch chat,
              Discord profile, and OBS.
            </p>
            <div className="ww-reveal ww-reveal-3 ww-hero-actions">
              {/* Desktop primary: the .dmg itself. Phones get SendToMac
                  instead (CSS swap, see .ww-cta-desktop / .ww-cta-phone). */}
              <a
                href={downloadUrl}
                className="ww-btn ww-btn-primary ww-btn-lg ww-download-cta ww-cta-desktop"
              >
                <Download className="w-4 h-4" aria-hidden="true" />
                Download for Mac
              </a>
              <SendToMac
                url={downloadPageUrl}
                className="ww-btn ww-btn-primary ww-btn-lg ww-download-cta ww-cta-phone"
              />
              <Link href="/download" className="ww-hero-install-link">
                Other install options
                <ArrowRight className="w-4 h-4" aria-hidden="true" />
              </Link>
            </div>
            <p className="ww-reveal ww-reveal-3 ww-hero-reassurance">
              <Check className="w-4 h-4" aria-hidden="true" />
              macOS 26+ · Apple Silicon · Free
            </p>
          </div>

          <div className="ww-reveal ww-reveal-2 ww-hero-stage">
            <HeroPlayer />
          </div>
        </div>
      </section>

      <div aria-hidden="true" className="ww-legacy-anchors">
        {["chat", "more", "compare", "privacy", "dev-what", "dev-how", "dev-docs"].map((id) => <span id={id} key={id} />)}
      </div>
      <section
        id="audiences"
        className="ww-bg-surface px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-6xl">
          <CenterHead
            index="01"
            kicker="Your music, connected"
            title={<>One Mac app. Your whole stream.</>}
            sub="Play from the Music app. WolfWave takes care of the rest."
          />

          <div className="mt-14 grid md:grid-cols-3 gap-5">
            {[
              {
                icon: TwitchIcon,
                id: "twitch",
                title: "Let chat pick the next song.",
                body: "Viewers request with !sr. Approve songs or hold the queue, then choose Apple Music AutoPlay or a fallback playlist for what plays next.",
                href: "/docs/features#song-requests",
                cta: "Song request setup",
              },
              {
                icon: MessageSquareText,
                id: "discord",
                title: "Share what’s playing.",
                body: "Your Discord profile shows the current song, album art, and live progress. No bot or Discord server setup.",
                href: "/docs/features#discord-status",
                cta: "Discord setup",
              },
              {
                id: "developers",
                icon: Music,
                title: "Built for your Mac.",
                body: "A native menu bar app, with optional Stream Deck controls. Turn on the integrations you need and keep your credentials in Keychain.",
                href: "/docs/features#menu-bar-and-music-sync",
                cta: "Mac app guide",
              },
            ].map(({ id, icon: Icon, title, body, href, cta }) => (
              <Link
                key={title}
                id={id}
                href={href}
                data-scroll-reveal
                className="ww-card ww-bg-base flex flex-col p-6 md:p-8 scroll-mt-24"
              >
                <div
                  className="w-11 h-11 rounded-xl inline-flex items-center justify-center mb-5"
                  style={{
                    backgroundColor: "var(--brand-50)",
                    color: "var(--brand-600)",
                  }}
                >
                  <Icon className="w-5 h-5" />
                </div>
                <h3 className="ww-display ww-text-1 text-xl mb-2">{title}</h3>
                <p className="ww-text-2 text-base leading-relaxed flex-1">
                  {body}
                </p>
                <span
                  className="ww-text-brand mt-5 inline-flex items-center gap-1.5 text-sm font-semibold"
                >
                  {cta}
                  <ArrowRight className="w-3.5 h-3.5" />
                </span>
              </Link>
            ))}
          </div>
        </div>
      </section>

      <section
        id="overlay"
        className="ww-bg-base px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-6xl grid md:grid-cols-2 gap-12 lg:gap-16 items-center">
          <div data-scroll-reveal className="text-center md:text-left">
            <Kicker index="02">Stream overlay</Kicker>
            <h2 className="ww-display ww-text-1 text-4xl sm:text-5xl mt-5">
              Your music. On the scene.
            </h2>
            <p className="ww-text-2 text-lg mt-5 leading-relaxed">
              Add one browser source to OBS. Pick a theme and layout below,
              then make it yours in WolfWave.
            </p>
            <Link
              href="/docs/features#now-playing-widget"
              className="ww-text-brand mt-6 inline-flex items-center gap-1.5 text-sm font-semibold"
            >
              Set up the overlay
              <ArrowRight className="w-3.5 h-3.5" aria-hidden="true" />
            </Link>
          </div>

          <figure data-scroll-reveal className="mx-auto w-full" style={{ maxWidth: 560 }}>
            <div
              className="rounded-2xl overflow-hidden"
              style={{
                border: "1px solid var(--hairline)",
                boxShadow: "0 10px 28px -18px rgba(0,0,0,0.22)",
              }}
              role="group"
              aria-label="WolfWave overlay rendered inside an OBS browser source"
            >
              <div
                className="px-4 py-2.5 flex items-center gap-2 text-xs ww-mono ww-text-2"
                style={{
                  backgroundColor: "var(--bg-surface)",
                  borderBottom: "1px solid var(--hairline)",
                }}
                aria-hidden="true"
              >
                <span
                  className="w-2.5 h-2.5 rounded-full"
                  style={{ background: "#ff5f57" }}
                />
                <span
                  className="w-2.5 h-2.5 rounded-full"
                  style={{ background: "#febc2e" }}
                />
                <span
                  className="w-2.5 h-2.5 rounded-full"
                  style={{ background: "#28c840" }}
                />
                <span className="ml-2">localhost:8766/</span>
              </div>
              <div
                style={{
                  // Stage backdrop. Neutral checkerboard to read as "browser source"
                  backgroundColor: "#0d0d0f",
                  backgroundImage:
                    "linear-gradient(45deg, rgba(255,255,255,0.025) 25%, transparent 25%), linear-gradient(-45deg, rgba(255,255,255,0.025) 25%, transparent 25%), linear-gradient(45deg, transparent 75%, rgba(255,255,255,0.025) 75%), linear-gradient(-45deg, transparent 75%, rgba(255,255,255,0.025) 75%)",
                  backgroundSize: "16px 16px",
                  backgroundPosition: "0 0, 0 8px, 8px -8px, -8px 0",
                }}
              >
                <OBSOverlayWidget />
              </div>
            </div>
            <DemoCaption as="figcaption">Demo. Songs are made up.</DemoCaption>
          </figure>
        </div>
      </section>

      <section
        id="faq"
        className="ww-bg-surface px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-3xl">
          <CenterHead
            index="03"
            kicker="Before you download"
            title={<>A few things worth knowing.</>}
            sub="The common questions, answered. Setup details live in the full FAQ."
          />

          <div className="mt-12 space-y-3">
            {landingFaq.map((item) => (
              <FaqRow key={item.q} q={item.q} a={item.node} />
            ))}
          </div>

          <p className="mt-10 text-center text-sm ww-text-2">
            More questions?{" "}
            <Link href="/docs/faq" className="ww-text-brand font-semibold">
              Read the full FAQ
            </Link>{" "}
            or{" "}
            <a
              href={DISCORD_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="ww-text-brand font-semibold"
            >
              ask in Discord
            </a>
            .
          </p>
        </div>
      </section>

      <section id="cta" className="ww-bg-base px-[10%] md:px-6 py-28 sm:py-36 scroll-mt-20">
        <div data-scroll-reveal className="mx-auto max-w-4xl text-center">
          <div
            className="w-12 h-12 rounded-2xl inline-flex items-center justify-center mb-6 mx-auto"
            style={{
              backgroundColor: "var(--brand-50)",
              color: "var(--brand-500)",
            }}
          >
            <Music className="w-5 h-5" />
          </div>
          <h2 className="ww-display ww-text-1 text-5xl sm:text-6xl lg:text-7xl">
            Press play.
            <br />
            <span className="ww-text-brand">We&apos;ll handle the rest.</span>
          </h2>
          <div className="mt-10 flex flex-col sm:flex-row items-center justify-center gap-3">
            <a
              href={downloadUrl}
              className="ww-btn ww-btn-primary w-full sm:w-auto ww-cta-desktop"
            >
              <Download className="w-4 h-4" aria-hidden="true" />
              Download for Mac
            </a>
            <SendToMac
              url={downloadPageUrl}
              className="ww-btn ww-btn-primary w-full sm:w-auto ww-cta-phone"
            />
            <Link
              href="/docs"
              className="ww-btn ww-btn-secondary w-full sm:w-auto"
            >
              Read the docs
              <ArrowRight className="w-4 h-4" />
            </Link>
          </div>
          <p className="mt-5 text-sm ww-text-2">
            Free forever · macOS 26+ · Apple Silicon · Apple Music
          </p>
          <p className="mt-2 text-sm ww-text-2 ww-phone-only">
            WolfWave installs on a Mac. Send yourself the link.
          </p>
        </div>
      </section>

    </main>
  );
}
