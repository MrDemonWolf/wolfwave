import type { ReactNode } from "react";
import { HomeSearch } from "@/components/docs/home-search";

/**
 * Building blocks for the docs home (`content/docs/index.mdx`). The home is a
 * help page, not a pitch: a plain header with search, then short groups of
 * links sorted by what a reader came to do. Each group's links are plain
 * Markdown, so the home is edited like any other page and reads cleanly in
 * llms.txt.
 */

/** The home's one `<h1>`, a one-line lede and the search field. Styled like every other page's header. */
export function HomeHeader({ title, lede }: { title: string; lede: string }) {
  return (
    <header className="ww-home-head not-prose">
      <h1>{title}</h1>
      <p>{lede}</p>
      <HomeSearch />
    </header>
  );
}

/** Lays out `LinkGroup`s two across when the page column has room, else one. */
export function HomeGrid({ children }: { children: ReactNode }) {
  return <div className="ww-home-grid not-prose">{children}</div>;
}

/**
 * A titled inset list, like a System Settings group. Put a Markdown list
 * inside with one link per item. A numbered list (`1.`) shows its step
 * numbers, so use one only when the steps really are done in order.
 */
export function LinkGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="ww-link-group">
      <h2>{title}</h2>
      {children}
    </section>
  );
}
