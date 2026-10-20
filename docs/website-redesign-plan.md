# WolfWave website redesign

Prepared and implemented on 2026-10-20. Changes remain local for review.

## Direction

Make the product the centerpiece: one Mac app preview, a short pitch, and one primary download action. Keep the existing blue identity, flat surfaces, stable section anchors, and direct Mac download path. Use movement as sections enter on scroll and give visitors a way to pause previews.

Research informed the layout rather than supplying assets:

- Native Mac references: [Maccy](https://maccy.app/) and [Rectangle](https://rectangleapp.com/) for single-purpose clarity; [CleanShot](https://cleanshot.com/) for restrained blue surfaces. Use one faint blue wash behind the product, with neutral backgrounds elsewhere. Background imagery is unnecessary unless it explains the actual app.

- Mobbin's [Sketch product hero](https://mobbin.com/sites/sections/a8e27ceb-5766-47e1-922e-e320d5a95fa0) and [second Sketch reference](https://mobbin.com/sites/sections/911d63f6-cba8-4a11-bc77-0f06b4a648c6): concise pitch, prominent product, compact platform proof.
- [MrDemonWolf website typography](https://github.com/mrdemonwolf/website/blob/main/apps/website/src/styles/site.css): Montserrat headings, Roboto body, JetBrains Mono code; 16px body, 74px desktop hero, 48px desktop section headings, responsive reductions.
- W3C [minimum contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) and [enhanced contrast](https://www.w3.org/WAI/WCAG21/Understanding/contrast-enhanced): AA minimum for component text, AAA for the shared opaque text/surface pairs.
- Google [supported meta tags](https://developers.google.com/search/docs/crawling-indexing/special-tags): improve descriptive titles, snippets, content, canonicals, and structured data. Meta keywords are descriptive metadata and do not improve Google's rankings.

## Implemented scope

- [x] Use one hero app preview with the existing shared demo clock; show the interactive overlay further down the page.
- [x] Remove the nested stage, duplicate output, connection chips, and proof badges. Keep responsive typography and short entrances without an animation dependency.
- [x] Reduce the landing page to five sections: hero, three feature summaries, overlay, six common questions, and download. Keep long-form detail in contextual docs links.
- [x] Use observed 16px entrances lasting 450ms, replaying when visitors scroll away and return. Reduced-motion changes cancel active animations; content remains visible.

## Production motion references

- [Motion's viewport guidance](https://motion.dev/docs/react-scroll-animations) separates triggered entrances from effects tied continuously to scroll position. WolfWave uses triggered entrances, with replay requested by the owner.
- [web.dev's animation guide](https://web.dev/articles/animations-guide) recommends checking rendering cost and preferring transform and opacity. WolfWave moves content with transform only and keeps text opaque.
- [Reduced motion guidance](https://web.dev/articles/prefers-reduced-motion) informs the preference listener and immediate cancellation.

The 16px distance and 450ms duration are WolfWave design choices, not measurements copied from another website. Avoid stacked animations on a preview and its container, scroll hijacking, and decorative continuous motion.
- [x] Trim the main navigation to Features → Changelog → Docs, with Download separate. Supporting links stay in the footer.
- [x] Improve the full FAQ with five topic groups, a jump list, practical setup links, and a distinct troubleshooting path.
- [x] Add an explicit Pause previews control; verify that the shared track clock holds and resumes.
- [x] Add public `/changelog/` using the existing release source. Remove Unreleased sections before MDX, search, TOC, and text exports compile. Keep `/docs/changelog/` as a noindex compatibility page with the public canonical.
- [x] Add public `/design-system/` with token-driven type samples, light/dark contrast ratios, shared actions, and keyboard-accessible motion timing samples.
- [x] Update shared typography and contrast tokens; regenerate CSS, Swift, widget data, and bundled widget HTML.
- [x] Preserve artwork DOM and Vinyl rotation on duplicate overlay snapshots and unchanged preview settings. Replace animated container blur with opacity/transform transitions.
- [x] Check preset text contrast against composited black/white scenes, white artwork, and decorative noise. Keep custom scene/color checks explicit.
- [x] Sync README, release sources, contributor instructions, widget documentation, and design-system foundations.

## Boundaries

The shipped OBS widget and the native WKWebView settings preview load the same generated `widget.html`; changing that source reaches both. The marketing overlay is a React recreation using the same generated themes and layout dimensions. Its sample artwork and tracks are deliberately fictional.

Native controls retain their macOS type sizes. Additive web size tokens avoid changing the density of every native pane. No new font dependency or animation package was added; Next.js hosts the web fonts locally in the exported site.

AA text contrast means at least 4.5:1 for normal text; AAA means 7:1. Passing selected token pairs does not certify the entire website or app. Transparent/custom overlays still require the real scene, font size, and final compositing to be checked.

## Verification and handoff

See [the UI review](website-ui-review.md) for tested views, measurements, and remaining device checks. Build/test outcomes are recorded there after integration.

- [ ] Profile the real OBS browser source during playback, rapid skipping, scene hiding, and reconnects.
- [ ] Inspect the signed native WKWebView appearance preview on a Mac with the updated bundle.
- [ ] Run VoiceOver and actual browser zoom at 200% before claiming full accessibility conformance.
- [ ] After deployment, verify production URLs and refresh cached social previews; submit the sitemap in search tools.
