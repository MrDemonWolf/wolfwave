import { Instrument_Sans } from "next/font/google";
import type { Metadata } from "next";
import { Provider } from "@/components/provider";
import { siteUrl, basePath, absoluteUrl, homepageSeo } from "@/lib/site";
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
 * Root layout: font variable, skip link, and the Fumadocs provider. JSON-LD is
 * per page (see `lib/seo.ts`), so a docs page or the 404 never claims to be the
 * app itself.
 */
export default function Layout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={instrumentSans.variable} suppressHydrationWarning>
      <body className="flex flex-col min-h-screen">
        <a href="#nd-page" className="skip-nav">
          Skip to content
        </a>
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
