import { JetBrains_Mono, Montserrat, Roboto } from "next/font/google";
import type { Metadata } from "next";
import { Provider } from "@/components/provider";
import { siteUrl, basePath, absoluteUrl, homepageSeo } from "@/lib/site";
import "./global.css";

// Match the MrDemonWolf website's type families, self-hosted by Next at build time.
const montserrat = Montserrat({
  subsets: ["latin"],
  variable: "--font-montserrat",
  display: "swap",
});
const roboto = Roboto({ subsets: ["latin"], variable: "--font-roboto", display: "swap" });
const jetbrainsMono = JetBrains_Mono({ subsets: ["latin"], variable: "--font-jetbrains", display: "swap" });

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
    <html lang="en" className={`${montserrat.variable} ${roboto.variable} ${jetbrainsMono.variable}`} suppressHydrationWarning>
      <body className="flex flex-col min-h-screen">
        <a href="#nd-page" className="skip-nav">
          Skip to content
        </a>
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
