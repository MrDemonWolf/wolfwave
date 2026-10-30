import type { LucideIcon } from "lucide-react";
import {
  ArchiveRestore,
  Boxes,
  Cable,
  ChartColumn,
  CircleHelp,
  Component,
  Download,
  EyeOff,
  FileText,
  Grid2x2,
  Hammer,
  HandHeart,
  House,
  LifeBuoy,
  Library,
  LockKeyhole,
  MessageSquareText,
  MonitorPlay,
  MoonStar,
  Palette,
  Scale,
  ScrollText,
  Settings,
  Shield,
  Sparkles,
  Stamp,
  SwatchBook,
} from "lucide-react";

/**
 * Docs navigation model: which sidebar tab each `meta.json` group belongs to,
 * plus the sidebar's short labels and icon tiles. Page order and group names
 * stay in `content/docs/meta.json`; `lib/docs-tree.ts` reads both and builds the
 * tabbed page tree, so moving a page is a `meta.json` edit and nothing moves on
 * disk (every URL, anchor and file path stays put).
 */

/**
 * Tile colors, named for what a page is about: WolfWave itself (`brand`), a
 * partner service (its brand color), general and legal pages (`gray`), fixes
 * (`red`), contributor docs (`indigo`), and the design system (`wolfwave`).
 * Each maps to a design token in `app/docs/docs.css`.
 */
export type TileTint =
  | "brand"
  | "indigo"
  | "gray"
  | "red"
  | "twitch"
  | "discord"
  | "apple-music"
  | "graphite"
  | "wolfwave";

/** One sidebar tab. Stamped on its page-tree folder as a typed `root`. */
export interface DocsTab {
  id: "guides" | "developers" | "design-system";
  /** Tab name in the sidebar switcher and search filter. */
  title: string;
  /** Where the switcher goes. Always the tab's first page. */
  url: string;
  /**
   * `meta.json` separator names in this tab, in order. The first tab also
   * takes the pages listed before the first separator (the docs home).
   */
  groups: string[];
}

export const DOCS_TABS: readonly DocsTab[] = [
  {
    id: "guides",
    title: "Guides",
    url: "/docs",
    groups: ["Start here", "On stream", "Your Mac", "Help", "Legal"],
  },
  {
    id: "developers",
    title: "Developers",
    url: "/docs/development",
    groups: ["Contribute", "Integrate"],
  },
  {
    id: "design-system",
    title: "Design",
    url: "/docs/design-system",
    groups: ["Design System"],
  },
];

/** Groups whose name would only repeat the tab's, so the sidebar skips the label. */
export const HIDDEN_GROUP_LABELS: ReadonlySet<string> = new Set(["Design System"]);

/** Sidebar presentation for one page or link. */
export interface DocsNavEntry {
  /** Shorter sidebar label. The page title and `<h1>` are unchanged. */
  label?: string;
  icon: LucideIcon;
  tint: TileTint;
}

/** Keyed by URL, so `meta.json` links (like the changelog) get a tile too. */
export const DOCS_NAV_ENTRIES: Readonly<Record<string, DocsNavEntry>> = {
  "/docs": { label: "Overview", icon: House, tint: "brand" },
  "/docs/installation": { icon: Download, tint: "brand" },
  "/docs/features": { icon: Sparkles, tint: "brand" },
  "/docs/bot-commands": { icon: MessageSquareText, tint: "twitch" },
  "/docs/streamdeck": { icon: Grid2x2, tint: "graphite" },
  "/docs/streamer-mode": { icon: EyeOff, tint: "brand" },
  "/docs/settings": { icon: Settings, tint: "gray" },
  "/docs/backup": { icon: ArchiveRestore, tint: "gray" },
  "/docs/listening-history": { label: "Listening History", icon: ChartColumn, tint: "apple-music" },
  "/docs/nightly": { icon: MoonStar, tint: "gray" },
  "/docs/troubleshooting": { icon: LifeBuoy, tint: "red" },
  "/docs/faq": { label: "FAQ", icon: CircleHelp, tint: "gray" },
  "/docs/support": { label: "Help & Support", icon: HandHeart, tint: "gray" },
  "/docs/comparison": { label: "Compare Alternatives", icon: Scale, tint: "gray" },
  "/changelog": { icon: ScrollText, tint: "gray" },
  "/docs/privacy-policy": { icon: Shield, tint: "gray" },
  "/docs/terms-of-service": { icon: FileText, tint: "gray" },
  "/docs/acknowledgements": { label: "Acknowledgements", icon: Library, tint: "gray" },
  "/docs/development": { icon: Hammer, tint: "indigo" },
  "/docs/architecture": { icon: Boxes, tint: "indigo" },
  "/docs/security": { icon: LockKeyhole, tint: "indigo" },
  "/docs/widget": { label: "OBS Widget", icon: MonitorPlay, tint: "graphite" },
  "/docs/stream-deck": { label: "Stream Deck Protocol", icon: Cable, tint: "graphite" },
  "/docs/design-system": { label: "Overview", icon: Palette, tint: "wolfwave" },
  "/docs/design-system/foundations": { icon: SwatchBook, tint: "wolfwave" },
  "/docs/design-system/components": { label: "Components", icon: Component, tint: "wolfwave" },
  "/docs/design-system/brand": { icon: Stamp, tint: "wolfwave" },
};
