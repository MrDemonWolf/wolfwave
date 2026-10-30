"use client";
import Link from "fumadocs-core/link";
import { useTreeContext } from "fumadocs-ui/contexts/tree";
import { DOCS_TABS } from "@/lib/docs-nav";

/**
 * The sidebar's section switcher: Guides, Developers, Design. A macOS-style
 * segmented control made of links. The active segment is the tab whose
 * page-tree folder holds the current page (Fumadocs scopes the sidebar to
 * that folder), so it can never disagree with the list below it.
 */
export function DocsTabs() {
  const { root } = useTreeContext();
  const active = "root" in root && typeof root.root === "string" ? root.root : DOCS_TABS[0].id;

  return (
    <nav aria-label="Docs sections" className="ww-tabs">
      {DOCS_TABS.map((tab) => (
        <Link
          key={tab.id}
          href={tab.url}
          className="ww-tab"
          data-active={tab.id === active}
          aria-current={tab.id === active ? "true" : undefined}
        >
          {tab.title}
        </Link>
      ))}
    </nav>
  );
}
