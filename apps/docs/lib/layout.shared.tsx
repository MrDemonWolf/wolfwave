import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared";
import { getAssetPath } from "@/lib/utils";

/** Shared Fumadocs nav, links, and theme options for the docs layout (and any layout reusing it). */
export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: (
        <span data-ww-brand className="inline-flex items-center gap-2.5">
          {/* Static export with a base path: a plain <img> is the right tag for a
              tiny inline SVG logo; next/image would add a loader for no gain. */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={getAssetPath("/logo.svg")}
            alt=""
            aria-hidden="true"
            className="h-7 w-auto"
          />
          <span className="font-[var(--font-montserrat)] text-[1.05rem] font-semibold tracking-tight text-[var(--txt-1)]">
            WolfWave
          </span>
        </span>
      ),
      url: "/",
      transparentMode: "top",
    },
    links: [
      // Landing-section anchors. On the home page these scroll; from any other
      // page they navigate home and then jump to the section.
      { text: "Features", url: "/#audiences" },
      // Real pages. `active: nested-url` keeps the item lit on the page and its
      // children, so the nav always shows where you are.
      { text: "Changelog", url: "/changelog", active: "url" },
      { text: "Docs", url: "/docs", active: "nested-url" },
      { type: "button", text: "Download", url: "/download", active: "url", secondary: true },
    ],
    themeSwitch: {
      enabled: true,
      mode: "light-dark-system",
    },
    searchToggle: {
      enabled: true,
    },
  };
}
