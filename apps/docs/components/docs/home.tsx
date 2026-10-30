import type { CSSProperties, ReactNode } from "react";
import Link from "next/link";
import {
  Cable,
  ChartColumn,
  ChevronRight,
  Code,
  Download,
  Grid2x2,
  Hammer,
  Headphones,
  LifeBuoy,
  ListMusic,
  MessageSquareText,
  MonitorPlay,
  Music,
  Settings,
  type LucideIcon,
} from "lucide-react";
import { IconTile } from "@/components/docs/icon-tile";
import type { TileTint } from "@/lib/docs-nav";
import { getAssetPath } from "@/lib/utils";

/**
 * Building blocks for the docs home (`content/docs/index.mdx`). Each takes its
 * copy from MDX, so the home is edited like any other page. Icons are picked
 * by name from `HOME_ICONS` to keep the MDX free of imports.
 */

const HOME_ICONS = {
  cable: Cable,
  chart: ChartColumn,
  chat: MessageSquareText,
  code: Code,
  download: Download,
  grid: Grid2x2,
  hammer: Hammer,
  headphones: Headphones,
  lifebuoy: LifeBuoy,
  monitor: MonitorPlay,
  music: Music,
  requests: ListMusic,
  settings: Settings,
} satisfies Record<string, LucideIcon>;

export type HomeIcon = keyof typeof HOME_ICONS;

/**
 * MDX isn't type-checked, so a mistyped icon name would otherwise fail the
 * build with React's generic "Element type is invalid". Name it instead.
 */
function homeIcon(name: HomeIcon): LucideIcon {
  const icon = HOME_ICONS[name];
  if (!icon) {
    throw new Error(`Unknown docs home icon "${name}". Use one of: ${Object.keys(HOME_ICONS).join(", ")}.`);
  }
  return icon;
}

/** An icon tile by name, for MDX (`<Tile icon="hammer" tint="indigo" />`). */
export function Tile({ icon, tint, size = "md" }: { icon: HomeIcon; tint: TileTint; size?: "sm" | "md" | "lg" }) {
  return <IconTile icon={homeIcon(icon)} tint={tint} size={size} />;
}

/** The home's one `<h1>`, its lede and two actions, beside the menu map. */
export function HomeHero({
  title,
  primary,
  secondary,
  children,
  aside,
}: {
  title: string;
  primary: { href: string; label: string };
  secondary: { href: string; label: string };
  /** The lede. */
  children: ReactNode;
  /** Usually a `<MenuMap>`. */
  aside?: ReactNode;
}) {
  return (
    <section className="ww-docs-hero not-prose">
      <div className="ww-docs-hero-copy">
        <h1>{title}</h1>
        <div className="ww-docs-lede">{children}</div>
        <div className="ww-docs-actions">
          <Link className="ww-button" data-variant="primary" href={primary.href}>
            {primary.label}
          </Link>
          <Link className="ww-button" href={secondary.href}>
            {secondary.label}
          </Link>
        </div>
      </div>
      {aside}
    </section>
  );
}

/**
 * The docs, drawn as WolfWave's menu bar menu: the thing streamers already
 * click. Each row is a real link. The song is invented, and says so.
 */
export function MenuMap({ caption, children }: { caption: string; children: ReactNode }) {
  return (
    <figure className="ww-menu">
      <div className="ww-menu-bar" aria-hidden="true">
        <span
          className="ww-menu-bar-wolf"
          style={{ "--ww-logo": `url("${getAssetPath("/logo.svg")}")` } as CSSProperties}
        />
        <span className="ww-menu-bar-dot" />
        <span className="ww-menu-bar-dot" />
        <span className="ww-menu-bar-clock">9:41</span>
      </div>
      <div className="ww-menu-panel">
        <div className="ww-menu-now" aria-hidden="true">
          <span className="ww-menu-art" />
          <span className="ww-menu-track">
            <strong>Moonlit Howl</strong>
            <span>Arctic Wolf</span>
          </span>
        </div>
        <nav aria-label="Docs shortcuts" className="ww-menu-items">
          {children}
        </nav>
      </div>
      <figcaption>{caption}</figcaption>
    </figure>
  );
}

/** One row of the menu map. `separator` draws a hairline above it, like a menu group. */
export function MenuMapItem({
  href,
  icon,
  tint,
  shortcut,
  separator,
  children,
}: {
  href: string;
  icon: HomeIcon;
  tint: TileTint;
  shortcut?: string;
  separator?: boolean;
  children: ReactNode;
}) {
  return (
    <Link className="ww-menu-item" data-separator={separator ? "" : undefined} href={href}>
      <IconTile icon={homeIcon(icon)} tint={tint} />
      <span className="ww-menu-label">{children}</span>
      {/* The shortcut is part of the drawing, not the link's name. */}
      {shortcut ? <kbd aria-hidden="true">{shortcut}</kbd> : <ChevronRight aria-hidden="true" className="ww-menu-chevron" />}
    </Link>
  );
}

/** A numbered path: the steps really are done in order. */
export function SetupPath({ children }: { children: ReactNode }) {
  return <ol className="ww-setup not-prose">{children}</ol>;
}

export function SetupStep({ href, title, children }: { href: string; title: string; children: ReactNode }) {
  return (
    <li>
      <Link href={href} className="ww-setup-step">
        <strong>{title}</strong>
        <span>{children}</span>
      </Link>
    </li>
  );
}

/** An inset grouped list of links, like a System Settings pane. */
export function LinkList({ children }: { children: ReactNode }) {
  return <ul className="ww-link-list not-prose">{children}</ul>;
}

export function LinkListItem({
  href,
  icon,
  tint,
  children,
}: {
  href: string;
  icon: HomeIcon;
  tint: TileTint;
  children: ReactNode;
}) {
  return (
    <li>
      <Link href={href}>
        <IconTile icon={homeIcon(icon)} tint={tint} />
        <span className="ww-link-label">{children}</span>
        <ChevronRight aria-hidden="true" />
      </Link>
    </li>
  );
}
