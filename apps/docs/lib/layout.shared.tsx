import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared";
import { getAssetPath } from "@/lib/utils";

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: (
        <span className="ww-nav-brand">
          <img src={getAssetPath("/logo.svg")} alt="" aria-hidden="true" />
          <span className="ww-nav-wordmark">WolfWave</span>
        </span>
      ),
      url: "/",
      transparentMode: "top",
    },
    githubUrl: "https://github.com/MrDemonWolf/WolfWave",
    links: [
      { text: "Docs", url: "/docs" },
      { text: "Support", url: "https://mrdwolf.net/discord" },
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
