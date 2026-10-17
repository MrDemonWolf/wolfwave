import type { Metadata } from "next";
import Link from "next/link";
import {
  STAR_CHIP_MIN,
  absoluteUrl,
  getLatestDmgUrl,
  getLatestRelease,
  getRepoStars,
  homepageSeo,
  pageUrl,
  repoUrl,
} from "@/lib/site";
import { buildFaqJsonLd, landingFaq } from "@/lib/faq";
import { homeGraphLd, jsonLdScript } from "@/lib/seo";
import {
  ArrowRight,
  Ban,
  Bell,
  BookOpen,
  ChartColumn,
  Check,
  Coins,
  Download,
  EyeOff,
  Gem,
  History,
  LayoutGrid,
  ListMusic,
  ListOrdered,
  MessageSquareText,
  Radio,
  Shield,
  ShieldCheck,
  Star,
  Tag,
  Music,
  CodeXml,
  ArrowLeftRight,
  Terminal,
  UserCheck,
  Vote,
  X as XIcon,
} from "lucide-react";
import { GithubIcon, TwitchIcon } from "@/components/icons";
import { DeveloperTabs } from "./DeveloperTabs";
import { DiscordPresenceCard } from "./_widgets/DiscordPresenceCard";
import { OBSOverlayWidget } from "./_widgets/OBSOverlayWidget";
import { TwitchChatPreview } from "./_widgets/TwitchChatPreview";
import { BackToTop } from "./_widgets/BackToTop";
import { ComparisonTable } from "./_widgets/ComparisonTable";
import { SendToMac } from "./_widgets/SendToMac";

const REPO_URL = repoUrl;
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
    <div className="max-w-3xl mx-auto text-center">
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
  // All three resolve at build time and degrade to "omit it" on failure, so
  // the proof row only ever shows numbers GitHub actually returned.
  const [downloadUrl, release, stars] = await Promise.all([
    getLatestDmgUrl(),
    getLatestRelease(),
    getRepoStars(),
  ]);
  const downloadPageUrl = pageUrl("/download");
  const faqJsonLd = buildFaqJsonLd();
  const siteJsonLd = homeGraphLd(release?.version ?? null, downloadUrl);

  return (
    <main id="nd-page" tabIndex={-1} className="ww-font ww-bg-base">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLdScript(siteJsonLd) }}
      />
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLdScript(faqJsonLd) }}
      />
      {/* ═══════════════ HERO ═══════════════ */}
      <section className="relative overflow-hidden">
        <div className="ww-hero-glow" aria-hidden="true" />
        <div className="ww-home-hero">
          <div className="ww-hero-copy">
            <p className="ww-reveal ww-reveal-1 ww-hero-eyebrow">
              <span className="ww-hero-eyebrow-dot" aria-hidden="true" />
              A native Mac app for Apple Music
            </p>
            <h1 className="ww-reveal ww-reveal-1 ww-hero-headline ww-text-1">
              Apple Music,
              <br />
              <span className="ww-text-brand">live on your stream.</span>
            </h1>
            <p className="ww-reveal ww-reveal-2 ww-hero-description ww-text-2">
              The free Mac app that puts Apple Music in your Twitch chat,
              Discord profile, and OBS. Chat requests songs. You stay in
              charge of what plays.
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
                <span className="ww-download-format">.dmg</span>
              </a>
              <SendToMac
                url={downloadPageUrl}
                className="ww-btn ww-btn-primary ww-btn-lg ww-download-cta ww-cta-phone"
              />
              <Link href="/download" className="ww-btn ww-btn-secondary ww-btn-lg">
                Other install options
                <ArrowRight className="w-4 h-4" aria-hidden="true" />
              </Link>
            </div>
            <p className="ww-reveal ww-reveal-3 ww-hero-reassurance">
              <Check className="w-4 h-4" aria-hidden="true" />
              macOS 26+ · Apple Silicon · Free
            </p>
            <p className="ww-reveal ww-reveal-3 ww-phone-only ww-phone-note">
              WolfWave installs on a Mac. Send yourself the link.
            </p>
            <ul className="ww-reveal ww-reveal-3 ww-proof" aria-label="Release facts">
              {release ? (
                <li>
                  <Link href="/docs/changelog" className="ww-proof-chip">
                    <Tag className="w-3.5 h-3.5" aria-hidden="true" />
                    Latest: v{release.version}
                  </Link>
                </li>
              ) : null}
              <li>
                <span className="ww-proof-chip">
                  <ShieldCheck className="w-3.5 h-3.5" aria-hidden="true" />
                  Signed &amp; notarized
                </span>
              </li>
              <li>
                <a
                  href={repoUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="ww-proof-chip"
                >
                  <GithubIcon className="w-3.5 h-3.5" aria-hidden="true" />
                  Open source
                </a>
              </li>
              {stars !== null && stars >= STAR_CHIP_MIN ? (
                <li>
                  <a
                    href={`${repoUrl}/stargazers`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="ww-proof-chip"
                  >
                    <Star className="w-3.5 h-3.5" aria-hidden="true" />
                    {stars.toLocaleString("en-US")} GitHub stars
                  </a>
                </li>
              ) : null}
            </ul>
          </div>

          <div className="ww-reveal ww-reveal-2 ww-hero-stage">
            <div className="ww-hero-stage-glow" aria-hidden="true" />
            <div
              className="ww-product-window"
              role="img"
              aria-label="WolfWave preview: Moonlit Howl is playing in Apple Music and syncing to Discord, Twitch, and OBS."
            >
              <div className="ww-product-header">
                <div className="ww-window-dots" aria-hidden="true">
                  <span />
                  <span />
                  <span />
                </div>
                <div className="ww-window-brand">
                  <span className="ww-window-brand-icon">
                    <Music className="w-4 h-4" aria-hidden="true" />
                  </span>
                  WolfWave
                </div>
                <span className="ww-live-status">
                  <span aria-hidden="true" /> LIVE
                </span>
              </div>

              <div className="ww-player-body">
                <p className="ww-player-overline">NOW PLAYING FROM APPLE MUSIC</p>
                <div className="ww-player-track">
                  <div className="ww-player-art" aria-hidden="true">
                    <Music className="w-8 h-8" />
                    <span className="ww-art-orbit" />
                  </div>
                  <div className="ww-player-metadata">
                    <strong>Moonlit Howl</strong>
                    <span>Arctic Wolf</span>
                    <span className="ww-player-album">Tundra Sessions</span>
                  </div>
                </div>
                <div className="ww-player-progress" aria-hidden="true">
                  <span />
                </div>
                <div className="ww-player-time" aria-hidden="true">
                  <span>1:14</span>
                  <span>3:38</span>
                </div>

                <div className="ww-sync-divider" />
                <div className="ww-sync-heading">
                  <span>YOUR STREAM, IN SYNC</span>
                  <span>3 CONNECTED</span>
                </div>
                <div className="ww-sync-destinations">
                  <span><i aria-hidden="true" /> Discord</span>
                  <span><i aria-hidden="true" /> Twitch</span>
                  <span><i aria-hidden="true" /> OBS Studio</span>
                </div>
              </div>
            </div>
            <p className="ww-stage-caption">
              Illustration. The song is made up.
            </p>
          </div>
        </div>
      </section>

      {/* ═══════════════ 01 · AUDIENCES ═══════════════ */}
      <section
        id="audiences"
        className="ww-bg-surface px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-6xl">
          <CenterHead
            index="01"
            kicker="Who it's for"
            title={<>Built for streamers. Fun for chat.</>}
            sub="Most streaming music tools were built for Spotify. WolfWave is built for Apple Music on a Mac. Pick the card that sounds like you."
          />

          <div className="mt-14 grid md:grid-cols-3 gap-5">
            {[
              {
                icon: TwitchIcon,
                title: "For streamers",
                body: "Play Apple Music on stream without the hacks. Chat requests songs, you approve or hold them, and the overlay and Discord keep up on their own.",
                href: "/docs/installation",
                cta: "Set it up",
              },
              {
                icon: MessageSquareText,
                title: "For your chat",
                body: "Viewers type !sr to request a song, !song to see what's playing, and !voteskip to skip it. Channel points and Bits work too, if the streamer turns them on.",
                href: "/#chat",
                cta: "What chat can type",
              },
              {
                icon: CodeXml,
                title: "For developers",
                body: "A real Apple Music feed to build on. A local WebSocket streams every play, pause, and skip. Wire it into anything in about 20 lines.",
                href: "/#developers",
                cta: "See the feed",
              },
            ].map(({ icon: Icon, title, body, href, cta }) => (
              <div
                key={title}
                className="ww-glass ww-card-hover flex flex-col p-6 md:p-8"
              >
                <div
                  className="w-11 h-11 rounded-xl inline-flex items-center justify-center mb-5"
                  style={{
                    backgroundColor: "var(--brand-50)",
                    color: "var(--brand-500)",
                  }}
                >
                  <Icon className="w-5 h-5" />
                </div>
                <h3 className="ww-display ww-text-1 text-xl mb-2">{title}</h3>
                <p className="ww-text-2 text-base leading-relaxed flex-1">
                  {body}
                </p>
                <Link
                  href={href}
                  className="ww-text-brand mt-5 inline-flex items-center gap-1.5 text-sm font-semibold"
                >
                  {cta}
                  <ArrowRight className="w-3.5 h-3.5" />
                </Link>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ═══════════════ 02 · TWITCH ═══════════════ */}
      <section
        id="twitch"
        className="ww-bg-base px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-6xl grid md:grid-cols-2 gap-12 lg:gap-16 items-center">
          <div className="text-center md:text-left">
            <Kicker index="02">Song requests</Kicker>
            <h2 className="ww-display ww-text-1 text-4xl sm:text-5xl mt-5">
              Chat picks the next song. You stay in charge.
            </h2>
            <p className="ww-text-2 text-lg mt-5 leading-relaxed">
              Requests come in from chat, channel points, or Bits, and play
              through Apple Music on your Mac. You decide how much control to
              hand over.
            </p>
            <ul className="mt-6 space-y-3 text-left max-w-md mx-auto md:mx-0">
              {[
                {
                  icon: UserCheck,
                  text: "Require My Approval holds every request until you approve or decline it.",
                },
                {
                  icon: ListOrdered,
                  text: "Fair-share order plays everyone's first request before anyone's second.",
                },
                {
                  icon: Ban,
                  text: "Block a song, a whole artist, or a person from requesting.",
                },
                {
                  icon: Vote,
                  text: "Chat can vote to skip. Hold the queue from chat, the menu bar, or a Stream Deck.",
                },
              ].map(({ icon: Icon, text }) => (
                <li key={text} className="flex gap-3 ww-text-2 text-base leading-relaxed">
                  <Icon
                    className="w-5 h-5 mt-0.5 shrink-0"
                    style={{ color: "var(--brand-500)" }}
                    aria-hidden="true"
                  />
                  <span>{text}</span>
                </li>
              ))}
            </ul>
            <div className="mt-6 flex flex-wrap justify-center md:justify-start gap-x-6 gap-y-3">
              <Link
                href="/docs/features#song-requests"
                className="ww-text-brand inline-flex items-center gap-1.5 text-sm font-semibold"
              >
                How song requests work
                <ArrowRight className="w-3.5 h-3.5" aria-hidden="true" />
              </Link>
              <Link
                href="/docs/bot-commands"
                className="ww-text-brand inline-flex items-center gap-1.5 text-sm font-semibold"
              >
                Every bot command
                <ArrowRight className="w-3.5 h-3.5" aria-hidden="true" />
              </Link>
            </div>
          </div>

          <figure className="m-0">
            <TwitchChatPreview />
            <DemoCaption as="figcaption">
              Demo. Chat and songs are made up.
            </DemoCaption>
          </figure>
        </div>
      </section>

      {/* ═══════════════ 03 · CHAT (what viewers can type) ═══════════════ */}
      <section
        id="chat"
        className="ww-bg-surface px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-6xl">
          <CenterHead
            index="03"
            kicker="For your chat"
            title={<>What your chat can do.</>}
            sub="Watching a stream that runs WolfWave? Type these in Twitch chat. The streamer picks which ones are switched on."
          />

          <ul className="mt-12 grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
            {[
              {
                icon: ListMusic,
                cmd: "!sr <song or link>",
                body: "Request a song. Type a name, or paste an Apple Music, Spotify, or YouTube link.",
              },
              {
                icon: Music,
                cmd: "!song",
                body: "See what's playing right now. !last shows the song before it.",
              },
              {
                icon: ListOrdered,
                cmd: "!queue",
                body: "See what's coming up. !myqueue shows only your own requests.",
              },
              {
                icon: Vote,
                cmd: "!voteskip",
                body: "Vote to skip the current song. Enough votes and it's gone. Short form: !vs.",
              },
              {
                icon: Gem,
                cmd: "Channel points",
                body: "Redeem “Request a Song” and type the song name. If the request fails, your points come back.",
              },
              {
                icon: Coins,
                cmd: "Bits",
                body: "Cheer with a song name to request it. Some streamers let a cheer bump your queued song to the front instead.",
              },
            ].map(({ icon: Icon, cmd, body }) => (
              <li
                key={cmd}
                className="ww-card ww-bg-base"
                style={{ border: "1px solid var(--hairline)" }}
              >
                <div className="flex items-center gap-3 mb-3">
                  <span
                    className="w-9 h-9 rounded-xl inline-flex items-center justify-center shrink-0"
                    style={{
                      backgroundColor: "var(--brand-50)",
                      color: "var(--brand-500)",
                    }}
                    aria-hidden="true"
                  >
                    <Icon className="w-4 h-4" />
                  </span>
                  <code className="ww-mono ww-text-1 text-base font-semibold break-words min-w-0">
                    {cmd}
                  </code>
                </div>
                <p className="ww-text-2 text-sm leading-relaxed">{body}</p>
              </li>
            ))}
          </ul>

          <p className="mt-8 text-center text-sm ww-text-2 max-w-2xl mx-auto leading-relaxed">
            Mods also get <code className="ww-mono ww-text-1">!skip</code>,{" "}
            <code className="ww-mono ww-text-1">!hold</code> /{" "}
            <code className="ww-mono ww-text-1">!resume</code>, and{" "}
            <code className="ww-mono ww-text-1">!clearqueue</code>. Channel
            points and Bits need a Twitch Affiliate or Partner channel.{" "}
            <Link href="/docs/bot-commands" className="ww-text-brand font-semibold">
              Every command
            </Link>
            .
          </p>
        </div>
      </section>

      {/* ═══════════════ 04 · DISCORD ═══════════════ */}
      <section
        id="discord"
        className="ww-bg-base px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-6xl grid md:grid-cols-2 gap-12 lg:gap-16 items-center">
          <figure
            className="order-2 md:order-1 mx-auto"
            style={{ width: "100%", maxWidth: 437 }}
          >
            <DiscordPresenceCard />
            <DemoCaption as="figcaption">Demo. Songs are made up.</DemoCaption>
          </figure>

          <div className="order-1 md:order-2 text-center md:text-left">
            <Kicker index="04">Discord Rich Presence</Kicker>
            <h2 className="ww-display ww-text-1 text-4xl sm:text-5xl mt-5">
              Your friends see what you&apos;re playing.
            </h2>
            <p className="ww-text-2 text-lg mt-5 leading-relaxed">
              Spotify users had this for years. Apple Music users got nothing.
              WolfWave puts real Rich Presence on your profile, with album art,
              live progress, and a tap through to the track.
            </p>
            <Link
              href="/docs/features#discord-status"
              className="ww-text-brand mt-6 inline-flex items-center gap-1.5 text-sm font-semibold"
            >
              Set up Discord status
              <ArrowRight className="w-3.5 h-3.5" aria-hidden="true" />
            </Link>
          </div>
        </div>
      </section>

      {/* ═══════════════ 05 · OVERLAY ═══════════════ */}
      <section
        id="overlay"
        className="ww-bg-surface px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-6xl grid md:grid-cols-2 gap-12 lg:gap-16 items-center">
          <div className="text-center md:text-left">
            <Kicker index="05">Stream overlay</Kicker>
            <h2 className="ww-display ww-text-1 text-4xl sm:text-5xl mt-5">
              A now-playing card for OBS in 30 seconds.
            </h2>
            <p className="ww-text-2 text-lg mt-5 leading-relaxed">
              Add one browser source in OBS, pick a theme and layout or build
              your own, and every track change shows up on stream the instant
              it happens. An optional ticker shows the next few requests.
            </p>
            <Link
              href="/docs/features#now-playing-widget"
              className="ww-text-brand mt-6 inline-flex items-center gap-1.5 text-sm font-semibold"
            >
              Set up the overlay
              <ArrowRight className="w-3.5 h-3.5" aria-hidden="true" />
            </Link>
          </div>

          <figure className="mx-auto w-full" style={{ maxWidth: 560 }}>
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

      {/* ═══════════════ 06 · MORE (streamer extras) ═══════════════ */}
      <section
        id="more"
        className="ww-bg-base px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-6xl">
          <CenterHead
            index="06"
            kicker="And the rest"
            title={<>The small stuff, handled.</>}
            sub="Everything here is optional. Turn on what helps and leave the rest off."
          />

          <div className="mt-12 grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
            {[
              {
                icon: LayoutGrid,
                title: "Stream Deck keys",
                body: "Twelve keys: play/pause, skip, approve, reject, hold the queue, announce the song, and more. The plugin is a manual install for now.",
                href: "/docs/streamdeck",
              },
              {
                icon: History,
                title: "History & Stats",
                body: "Opt-in and stays on your Mac. Top artists, listening time, a Monthly Wrap you can share, and !stats for chat while you're live.",
                href: "/docs/listening-history",
              },
              {
                icon: MessageSquareText,
                title: "Custom commands",
                body: "Make your own chat commands with variables like $user and $song. Send each one as a reply, a chat message, or an announcement.",
                href: "/docs/bot-commands",
              },
              {
                icon: EyeOff,
                title: "Streamer Mode",
                body: "One click hides your channel name, overlay links, and tokens, so you can show Settings on camera.",
                href: "/docs/streamer-mode",
              },
              {
                icon: ArrowLeftRight,
                title: "Move your settings",
                body: "Export your settings to a file and import them on another Mac. Logins stay behind, so you sign in to Twitch once per Mac.",
                href: "/docs/backup",
              },
              {
                icon: Bell,
                title: "Song-change banners",
                body: "Opt-in Mac notifications when the song changes or a vote-skip starts or passes. A new banner replaces the last one of its kind.",
                href: "/docs/features",
              },
            ].map(({ icon: Icon, title, body, href }) => (
              <Link
                key={title}
                href={href}
                className="ww-card ww-card-hover ww-bg-base block"
                style={{ border: "1px solid var(--hairline)" }}
              >
                <div
                  className="w-10 h-10 rounded-xl inline-flex items-center justify-center mb-4"
                  style={{
                    backgroundColor: "var(--brand-50)",
                    color: "var(--brand-500)",
                  }}
                  aria-hidden="true"
                >
                  <Icon className="w-5 h-5" />
                </div>
                <h3 className="ww-display ww-text-1 text-lg mb-2">{title}</h3>
                <p className="ww-text-2 text-sm leading-relaxed">{body}</p>
              </Link>
            ))}
          </div>
        </div>
      </section>

      {/* ═══════════════ 07 · COMPARISON ═══════════════ */}
      <section
        id="compare"
        className="ww-bg-surface px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-6xl">
          <CenterHead
            index="07"
            kicker="Honest comparison"
            title={<>Stop working around Apple Music.</>}
            sub="Most tools chase Spotify and bolt on Apple Music later, if ever. WolfWave starts with Apple Music. Free, native, and yours to fork."
          />

          {/* Old way vs. WolfWave: the streamer pain/solution pitch. */}
          <div className="mt-12 grid md:grid-cols-2 gap-4">
            <div
              className="ww-card ww-bg-base"
              style={{ border: "1px solid var(--hairline)" }}
            >
              <p className="ww-mono text-xs ww-text-2 mb-3">THE OLD WAY</p>
              <ul className="space-y-2.5 text-sm ww-text-2">
                {[
                  "Bolt on a third-party app or paid web service just to get your song on screen.",
                  "Switch your whole stream to Spotify or YouTube because nothing reads Apple Music.",
                  "Overlays that flicker or freeze every time the track changes.",
                  "No clean way to put Apple Music on your Discord profile.",
                ].map((item) => (
                  <li key={item} className="flex gap-2.5">
                    <XIcon
                      className="w-4 h-4 mt-0.5 shrink-0"
                      style={{ color: "var(--txt-2)" }}
                      aria-hidden="true"
                    />
                    <span>{item}</span>
                  </li>
                ))}
              </ul>
            </div>

            <div
              className="ww-card ww-bg-base"
              style={{
                border: "1px solid var(--hairline)",
                borderLeft: "2px solid var(--brand-500)",
              }}
            >
              <p className="ww-mono text-xs ww-text-brand mb-3">WITH WOLFWAVE</p>
              <ul className="space-y-2.5 text-sm ww-text-1">
                {[
                  "One menu-bar app reads Apple Music straight from your Mac.",
                  "One live feed powers the overlay. No flicker, no refresh.",
                  "Sign in once. Tokens are stored safely and reconnect on their own.",
                  "Discord “Listening to” status is built in. Just switch it on.",
                ].map((item) => (
                  <li key={item} className="flex gap-2.5">
                    <Check
                      className="w-4 h-4 mt-0.5 shrink-0"
                      style={{ color: "var(--brand-500)" }}
                      aria-hidden="true"
                    />
                    <span>{item}</span>
                  </li>
                ))}
              </ul>
            </div>
          </div>

          <ComparisonTable />

          <p className="mt-5 text-center text-xs ww-text-2 max-w-2xl mx-auto leading-relaxed">
            Columns describe typical tools in each category, not one product.
            Partial means it depends on the tool or your plan. See the{" "}
            <Link href="/docs/features" className="ww-text-brand font-semibold">
              full feature breakdown
            </Link>
            .
          </p>
        </div>
      </section>

      {/* ═══════════════ 08 · DEVELOPERS ═══════════════ */}
      <section
        id="developers"
        className="ww-bg-base ww-dev-dot-grid px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20 relative overflow-hidden"
        style={{
          backgroundSize: "32px 32px",
          backgroundPosition: "0 0",
        }}
      >
        <div className="mx-auto max-w-5xl relative">
          <CenterHead
            index="08"
            kicker="For developers"
            title={
              <>
                Built like a Swift app.
                <br />
                <span className="ww-text-brand">Hackable like a webhook.</span>
              </>
            }
            sub="Build on a live Apple Music feed in about 20 lines. A local WebSocket sends every play, pause, and skip to your overlay, a dashboard, or the official Stream Deck plugin (built from the repo until the Marketplace listing lands)."
          />

          {/* ── WHAT ─────────────────────────────────────────── */}
          <div id="dev-what" className="mt-14 scroll-mt-20">
            <h3 className="ww-mono text-xs ww-text-2 mb-4 text-center">
              WHAT IT IS
            </h3>
            <div className="grid md:grid-cols-3 gap-4">
              {[
                {
                  icon: CodeXml,
                  title: "Native Swift",
                  body: "A real macOS menu-bar app. Not an Electron wrapper, not a browser extension. Sandboxed, signed, and notarized.",
                },
                {
                  icon: Radio,
                  title: "Local WebSocket",
                  body: "ws://localhost:8765 streams track changes as JSON. Enable Stream Widgets in Settings and authenticate with your overlay token.",
                },
                {
                  icon: GithubIcon,
                  title: "Open source, GPL-3.0",
                  body: "Read the whole codebase on GitHub. Fork it, audit the security model, ship a custom build for your stream.",
                },
              ].map(({ icon: Icon, title, body }) => (
                <div
                  key={title}
                  className="ww-card ww-bg-base"
                  style={{ border: "1px solid var(--hairline)" }}
                >
                  <div
                    className="w-10 h-10 rounded-xl inline-flex items-center justify-center mb-4"
                    style={{
                      backgroundColor: "var(--brand-50)",
                      color: "var(--brand-500)",
                    }}
                  >
                    <Icon className="w-5 h-5" />
                  </div>
                  <h4 className="ww-display ww-text-1 text-lg mb-2">{title}</h4>
                  <p className="ww-text-2 text-sm leading-relaxed">{body}</p>
                </div>
              ))}
            </div>
          </div>

          {/* ── HOW ──────────────────────────────────────────── */}
          <div id="dev-how" className="mt-20 scroll-mt-20">
            <h3 className="ww-mono text-xs ww-text-2 mb-4 text-center">
              HOW IT WIRES UP
            </h3>
            <DeveloperTabs />
          </div>

          {/* ── DOCS ─────────────────────────────────────────── */}
          <div id="dev-docs" className="mt-20 scroll-mt-20">
            <h3 className="ww-mono text-xs ww-text-2 mb-4 text-center">
              WHERE TO GO NEXT
            </h3>
            <div className="grid sm:grid-cols-2 gap-4">
              {[
                {
                  icon: Terminal,
                  title: "Architecture",
                  body: "How the menu-bar app, services, and WebSocket feed fit together.",
                  href: "/docs/architecture",
                  external: false,
                },
                {
                  icon: BookOpen,
                  title: "Development guide",
                  body: "Build from source, run the test suite, contribute a PR.",
                  href: "/docs/development",
                  external: false,
                },
                {
                  icon: Shield,
                  title: "Security model",
                  body: "Keychain storage, code-signing, token validation, sandbox.",
                  href: "/docs/security",
                  external: false,
                },
                {
                  icon: GithubIcon,
                  title: "GitHub",
                  body: "Star the repo, fork it, or file an issue with reproduction steps.",
                  href: REPO_URL,
                  external: true,
                },
              ].map(({ icon: Icon, title, body, href, external }) => {
                const inner = (
                  <div className="flex items-start gap-4">
                    <div
                      className="w-10 h-10 rounded-xl inline-flex items-center justify-center shrink-0"
                      style={{
                        backgroundColor: "var(--brand-50)",
                        color: "var(--brand-500)",
                      }}
                    >
                      <Icon className="w-5 h-5" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <h4 className="ww-display ww-text-1 text-lg mb-1">
                        {title}
                      </h4>
                      <p className="ww-text-2 text-sm leading-relaxed">{body}</p>
                      <span className="ww-text-brand mt-3 inline-flex items-center gap-1.5 text-sm font-semibold">
                        Read
                        <ArrowRight className="w-3.5 h-3.5" />
                      </span>
                    </div>
                  </div>
                );
                const className = "ww-card ww-card-hover ww-bg-base block";
                const style = { border: "1px solid var(--hairline)" } as const;
                return external ? (
                  <a
                    key={title}
                    href={href}
                    target="_blank"
                    rel="noopener noreferrer"
                    className={className}
                    style={style}
                  >
                    {inner}
                  </a>
                ) : (
                  <Link
                    key={title}
                    href={href}
                    className={className}
                    style={style}
                  >
                    {inner}
                  </Link>
                );
              })}
            </div>
          </div>
        </div>
      </section>

      {/* ═══════════════ 09 · PRIVACY ═══════════════ */}
      <section
        id="privacy"
        className="ww-bg-base px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-3xl text-center">
          <div className="flex justify-center mb-5">
            <Kicker index="09">Your data</Kicker>
          </div>
          <h2 className="ww-display ww-text-1 text-4xl sm:text-5xl">
            No WolfWave servers. No tracking.
          </h2>
          <p className="ww-text-2 text-lg mt-5 leading-relaxed">
            Your plays go only to the services you turn on. Album art lookups
            ask Apple for cover art. Tokens stay in the macOS Keychain.
          </p>
          <p className="mt-4 text-sm">
            <Link href="/docs/privacy-policy" className="ww-text-brand font-semibold">
              Read the privacy policy
            </Link>
          </p>
          <div className="mt-8 flex flex-wrap items-center justify-center gap-2">
            {["Sandboxed", "Keychain", "No telemetry", "GPL-3.0 licensed"].map(
              (label) => (
                <span key={label} className="ww-pill">
                  {label}
                </span>
              ),
            )}
          </div>
        </div>
      </section>

      {/* ═══════════════ 10 · FAQ ═══════════════ */}
      <section
        id="faq"
        className="ww-bg-surface px-[10%] md:px-6 py-16 sm:py-24 lg:py-28 scroll-mt-20"
      >
        <div className="mx-auto max-w-3xl">
          <CenterHead
            index="10"
            kicker="Questions, answered"
            title={<>Anything else?</>}
            sub="The short answers. Longer ones live in the docs."
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

      {/* ═══════════════ CTA ═══════════════ */}
      <section id="cta" className="ww-bg-base px-[10%] md:px-6 py-28 sm:py-36 scroll-mt-20">
        <div className="mx-auto max-w-4xl text-center">
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
            <a
              href={REPO_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="ww-btn ww-btn-ghost w-full sm:w-auto"
            >
              <GithubIcon className="w-4 h-4" />
              Star on GitHub
            </a>
          </div>
          <p className="mt-5 text-sm ww-text-2">
            Free forever · macOS 26+ · Apple Silicon · Apple Music
          </p>
          <p className="mt-2 text-sm ww-text-2 ww-phone-only">
            WolfWave installs on a Mac. Send yourself the link.
          </p>
        </div>
      </section>

      {/* Landing-only floating back-to-top */}
      <BackToTop />
    </main>
  );
}
