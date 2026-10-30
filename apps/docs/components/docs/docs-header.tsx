"use client";
import type { ComponentProps } from "react";
import Link from "fumadocs-core/link";
import { usePathname } from "fumadocs-core/framework";
import { useNotebookLayout } from "fumadocs-ui/layouts/notebook";
import { PanelLeft } from "lucide-react";

/**
 * Docs top bar. Same pieces, order and look as the landing navbar (logo,
 * site links, search, theme, Download), so moving between the homepage and
 * the docs keeps one header. Replaces the Notebook layout's default header
 * slot; the sidebar trigger opens the page tree on phones.
 */
export function DocsHeader(props: ComponentProps<"header">) {
  const { slots, navItems } = useNotebookLayout();
  const pathname = usePathname();
  const links = navItems.filter((item) => item.type === undefined || item.type === "main");
  const buttons = navItems.filter((item) => item.type === "button");

  /** "page" on the exact page, "true" inside a section (Docs on a docs page), else undefined. */
  const currentState = (url: string, mode: "url" | "nested-url" | "none" = "url") => {
    if (mode === "none" || url.includes("#")) return undefined;
    const clean = url.replace(/\/$/, "");
    const current = pathname.replace(/\/$/, "");
    if (current === clean) return "page" as const;
    return mode === "nested-url" && current.startsWith(`${clean}/`) ? ("true" as const) : undefined;
  };

  return (
    <header id="nd-subnav" {...props} className="ww-docs-header">
      <div className="ww-docs-header-row">
        {slots.navTitle ? <slots.navTitle className="ww-docs-brand" /> : null}
        <nav aria-label="Site" className="ww-docs-header-links">
          {links.map((item) =>
            "url" in item && item.url ? (
              <Link
                key={item.url}
                href={item.url}
                data-active={currentState(item.url, item.active) !== undefined}
                aria-current={currentState(item.url, item.active)}
              >
                {item.text}
              </Link>
            ) : null,
          )}
        </nav>
        <div className="ww-docs-header-tools">
          {slots.searchTrigger ? (
            <>
              <slots.searchTrigger.full hideIfDisabled className="ww-docs-search" />
              <slots.searchTrigger.sm hideIfDisabled className="ww-docs-icon-button md:hidden" />
            </>
          ) : null}
          {slots.themeSwitch ? <slots.themeSwitch className="ww-docs-theme" /> : null}
          {buttons.map((item) =>
            "url" in item && item.url ? (
              <Link key={item.url} href={item.url} className="ww-docs-download">
                {item.text}
              </Link>
            ) : null,
          )}
          {slots.sidebar ? (
            <slots.sidebar.trigger className="ww-docs-icon-button md:hidden" aria-label="Open navigation">
              <PanelLeft aria-hidden="true" />
            </slots.sidebar.trigger>
          ) : null}
        </div>
      </div>
    </header>
  );
}
