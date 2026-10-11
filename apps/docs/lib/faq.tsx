import Link from "next/link";
import type { ReactNode } from "react";
import { repoUrl } from "@/lib/site";

/**
 * Landing-page FAQ. One list feeds both the visible `<details>` rows and the
 * homepage FAQPage JSON-LD, so the structured data can never say something the
 * page does not.
 *
 * `text` is the plain-text answer for JSON-LD; `node` is what the page renders.
 * Keep them saying the same thing. Every claim here must be true in the code:
 * the fallback poll is `AppleMusicSource.Constants.checkInterval` (5 s, slowed
 * in Low Power Mode), and Twitch-only perks (channel points, Bits, Polls) are
 * Affiliate/Partner features on Twitch's side.
 */
export interface FaqItem {
  q: string;
  text: string;
  node: ReactNode;
}

const link = "ww-text-brand font-semibold";

export const landingFaq: FaqItem[] = [
  {
    q: "Does it work with Spotify?",
    text: "No, and that's the point. Spotify already has plenty of tools. Apple Music had almost none, so that's what WolfWave is built for. If your setup is Spotify-first, this is not the right tool.",
    node: (
      <>
        No, and that&apos;s the point. Spotify already has plenty of tools.
        Apple Music had almost none, so that&apos;s what WolfWave is built for.
        If your setup is Spotify-first, this is not the right tool.
      </>
    ),
  },
  {
    q: "Does the music have to play on this Mac?",
    text: "Yes. WolfWave reads the Music app on the Mac it runs on. Songs playing on your iPhone, a HomePod by itself, or the Apple Music website won't show up. AirPlay from the Mac's Music app to speakers works fine.",
    node: (
      <>
        Yes. WolfWave reads the Music app on the Mac it runs on. Songs playing
        on your iPhone, a HomePod by itself, or the Apple Music website
        won&apos;t show up. AirPlay from the Mac&apos;s Music app to speakers
        works fine.
      </>
    ),
  },
  {
    q: "Do I need Twitch Affiliate?",
    text: "No. !song, !sr song requests, chat vote-to-skip, Discord status, and the overlay work on any channel. Channel-point requests, Bits boosts, and Twitch Polls vote-skip need Affiliate or Partner, because Twitch only offers those to them.",
    node: (
      <>
        No. <code className="ww-mono ww-text-1">!song</code>,{" "}
        <code className="ww-mono ww-text-1">!sr</code> song requests, chat
        vote-to-skip, Discord status, and the overlay work on any channel.
        Channel-point requests, Bits boosts, and Twitch Polls vote-skip need
        Affiliate or Partner, because Twitch only offers those to them.
      </>
    ),
  },
  {
    q: "Will my viewers see ads or upsells?",
    text: "Never. WolfWave is free and open source. No ads, no premium tier, no upsell screens. If you want to give back, you can sponsor the project.",
    node: (
      <>
        Never. WolfWave is free and open source. No ads, no premium tier, no
        upsell screens. If you want to give back,{" "}
        <Link href="/docs/support" className={link}>
          sponsor the project
        </Link>
        .
      </>
    ),
  },
  {
    q: "Does it slow down my stream?",
    text: "No. It's a native Mac app, not a browser tab. It listens for Apple Music's own song-change notifications, with a 5-second fallback check that slows down in Low Power Mode.",
    node: (
      <>
        No. It&apos;s a native Mac app, not a browser tab. It listens for Apple
        Music&apos;s own song-change notifications, with a 5-second fallback
        check that slows down in Low Power Mode.
      </>
    ),
  },
  {
    q: "Is my Twitch token safe?",
    text: "Yes. WolfWave signs in with Twitch's Device Code flow, so your password never touches the app. Tokens live in the macOS Keychain, never in a plain file. The app is sandboxed, signed, and notarized by Apple.",
    node: (
      <>
        Yes. WolfWave signs in with Twitch&apos;s Device Code flow, so your
        password never touches the app. Tokens live in the macOS Keychain,
        never in a plain file. The app is sandboxed, signed, and notarized by
        Apple.
      </>
    ),
  },
  {
    q: "Does it work on Intel Macs?",
    text: "No. WolfWave needs Apple Silicon (M1 or later) running macOS 26 (Tahoe) or newer.",
    node: (
      <>
        No. WolfWave needs Apple Silicon (M1 or later) running macOS 26 (Tahoe)
        or newer.
      </>
    ),
  },
  {
    q: "Can I use it on a second-PC OBS setup?",
    text: "Yes. The local WebSocket listens on your network, so an OBS PC on the same LAN can show the overlay. It uses a read-only overlay token. The separate control token (the one Stream Deck uses) only works from the Mac itself.",
    node: (
      <>
        Yes. The local WebSocket listens on your network, so an OBS PC on the
        same LAN can show the overlay. It uses a read-only overlay token. The
        separate control token (the one Stream Deck uses) only works from the
        Mac itself. See the{" "}
        <Link href="/docs/security" className={link}>
          security docs
        </Link>
        .
      </>
    ),
  },
  {
    q: "How do updates work?",
    text: "The DMG version updates itself with Sparkle, using signed update feeds. Homebrew installs update through Homebrew instead. Stable is the default; Settings → Software Update has an opt-in Nightly channel built from main.",
    node: (
      <>
        The DMG version updates itself with Sparkle, using signed update feeds.
        Homebrew installs update through Homebrew instead. Stable is the
        default; Settings → Software Update has an opt-in{" "}
        <Link href="/docs/nightly" className={link}>
          Nightly channel
        </Link>{" "}
        built from main.
      </>
    ),
  },
  {
    q: "Is it really free?",
    text: "Yes. GPL-3.0 licensed, no paywall, no premium tier. The whole source is on GitHub.",
    node: (
      <>
        Yes. GPL-3.0 licensed, no paywall, no premium tier. The whole source is
        on{" "}
        <a href={repoUrl} target="_blank" rel="noopener noreferrer" className={link}>
          GitHub
        </a>
        .
      </>
    ),
  },
];

/** schema.org FAQPage for the homepage, built from {@link landingFaq}. */
export function buildFaqJsonLd() {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: landingFaq.map((item) => ({
      "@type": "Question",
      name: item.q,
      acceptedAnswer: { "@type": "Answer", text: item.text },
    })),
  };
}
