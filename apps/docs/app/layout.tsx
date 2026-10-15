import { Instrument_Sans } from "next/font/google";
import type { Metadata } from "next";
import { Provider } from "@/components/provider";
import { siteUrl, basePath, absoluteUrl, pageUrl, homepageSeo, repoUrl, orgUrl, getLatestVersion } from "@/lib/site";
import { USER_THEMES, WIDGET_LAYOUTS } from "@/app/(home)/_widgets/widget-themes.generated";
import "./global.css";

// Display face for headlines (>= ~28px) only. Body/nav/UI text uses the
// system stack (SF Pro on Mac) instead, see .ww-font in global.css. We used
// to also load Unbounded for display type, but it's a wide/expanded web3
// display face (commissioned for Polkadot) that reads "crypto template" next
// to an Apple-style SF-set body and inflates hero line length on mobile.
// Instrument Sans keeps a grotesque skeleton close to SF Pro while adding
// just enough personality, so it now carries every display-sized heading.
const instrumentSans = Instrument_Sans({
  subsets: ["latin"],
  variable: "--font-instrument",
  display: "swap",
});

export const metadata: Metadata = {
  title: {
    default: homepageSeo.title,
    template: "%s | WolfWave",
  },
  description: homepageSeo.description,
  keywords: [
    "WolfWave",
    "Apple Music",
    "Twitch",
    "Discord",
    "Rich Presence",
    "macOS",
    "menu bar",
    "now playing",
    "stream overlay",
    "OBS",
    "chat bot",
    "WebSocket",
    "open source",
    "free",
    "streamer tools",
  ],
  authors: [{ name: "MrDemonWolf, Inc." }],
  creator: "MrDemonWolf, Inc.",
  icons: {
    icon: [
      { url: `${basePath}/icon.svg`, type: "image/svg+xml" },
      { url: `${basePath}/icon.png`, type: "image/png" },
    ],
    apple: `${basePath}/apple-icon.png`,
  },
  // No root `alternates.canonical` or `openGraph.url`: every child route would
  // inherit them and point its canonical at the homepage. Each page sets its
  // own (home + download in app/(home), docs in app/docs/[[...slug]]).
  openGraph: {
    type: "website",
    locale: "en_US",
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
  metadataBase: new URL(siteUrl),
};

/**
 * schema.org SoftwareApplication JSON-LD for the whole site.
 * @param softwareVersion latest release version, or null to omit the field.
 * Theme/layout counts in `featureList` come from the generated widget tokens so they track `tokens.json`.
 */
function buildJsonLd(softwareVersion: string | null) {
  return {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "WolfWave",
    description: homepageSeo.description,
    operatingSystem: "macOS 26.0",
    applicationCategory: "MultimediaApplication",
    applicationSubCategory: "Streaming",
    processorRequirements: "Apple Silicon",
    offers: {
      "@type": "Offer",
      price: "0",
      priceCurrency: "USD",
    },
    author: {
      "@type": "Organization",
      name: "MrDemonWolf, Inc.",
      url: orgUrl,
    },
    publisher: {
      "@type": "Organization",
      name: "MrDemonWolf, Inc.",
      url: orgUrl,
    },
    url: pageUrl("/"),
    downloadUrl: `${repoUrl}/releases/latest`,
    installUrl: pageUrl("/download"),
    // Derived from the latest GitHub release at build time; omitted entirely
    // when the fetch fails so we never ship a stale hardcoded version.
    ...(softwareVersion ? { softwareVersion } : {}),
    releaseNotes: pageUrl("/docs/changelog"),
    screenshot: absoluteUrl("/opengraph-image.png"),
    featureList: [
      "Apple Music now-playing to Twitch chat (!song, !last)",
      "Twitch song requests for Apple Music (!sr) with channel points and bits",
      "Discord Rich Presence, Listening to WolfWave with Apple Music album art",
      `OBS browser-source overlay with ${USER_THEMES.length} themes and ${Object.keys(WIDGET_LAYOUTS).length} layouts`,
      "Optional Elgato Stream Deck plugin with live state on every key (manual install for now)",
      "Vote-to-skip via chat or Twitch Polls",
      "macOS menu bar app",
    ],
    license: `${repoUrl}/blob/main/LICENSE`,
  };
}

/** Root layout: font variable, skip link, JSON-LD (fetched at build time), and the Fumadocs provider. */
export default async function Layout({ children }: LayoutProps<"/">) {
  const jsonLd = buildJsonLd(await getLatestVersion());
  return (
    <html lang="en" className={instrumentSans.variable} suppressHydrationWarning>
      <body className="flex flex-col min-h-screen">
        <a href="#nd-page" className="skip-nav">
          Skip to content
        </a>
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
