<!-- BEGIN:nextjs-agent-rules -->

## This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# AGENTS.md: docs site and landing page (`apps/docs/`)

> Paths in backticks are relative to the repo root unless they are links. Shared rules (CI, docs sync, versioning, release) are in the root [`AGENTS.md`](../../AGENTS.md).

The "keep docs in sync" rule (which pages to update for which change) is in the root [`AGENTS.md`](../../AGENTS.md#keep-docs-in-sync-do-not-let-these-drift).

## Documentation

Docs site built with Fumadocs (Next.js) at `apps/docs/`. Content in `apps/docs/content/docs/` as `.mdx` files. Page order and groups live in `apps/docs/content/docs/meta.json`: the home, Install, and Features first, then the On stream, Your Mac, Help, Legal, Developers, and Design groups. The sidebar is one plain list, like Ghostty's docs: `lib/docs-tree.ts` (a Fumadocs loader plugin) turns each `---Group---` separator into a collapsible folder and applies the short labels in `lib/docs-nav.ts` (`SIDEBAR_LABELS`), so no MDX file ever moves to change navigation. A label for a page that isn't in `meta.json`, or a group with no pages, fails `lib/docs-tree.test.ts`. Public release notes stay in the marketing navigation; the old docs changelog URL remains available for existing links. The Design group is docs-facing (`design-system/{index,foundations,components,brand}.mdx`), separate from the source-of-truth `design-system/` directory at the repo root. Deployed to GitHub Pages. Run with `bun run dev --filter docs` from root.

> **Two Stream Deck pages, one character apart.** `streamdeck.mdx` is the user-facing
> plugin walkthrough (On stream group); `stream-deck.mdx` is the control API reference
> (Developers group). Check which one you opened before editing.

### Docs website design flow

- **Docs shell (laid out like Ghostty's docs):** `app/docs/layout.tsx` uses the Fumadocs **Notebook** layout with `nav.mode: "top"`: a full-width top bar (`components/docs/docs-header.tsx`) that matches the landing navbar, and one plain sidebar on the page color. The home, Install, and Features sit on top, then a collapsible folder per group; folder names read in the text color, pages in the secondary color, and the current page is a solid brand row (the narrow-screen site links Fumadocs adds above the docs keep the current section bold instead). Each page (`app/docs/[[...slug]]/page.tsx`) shows a docs home › group breadcrumb and a **Copy Markdown** button (it fetches the static `/llms.mdx/docs/<slug>.md` file from `app/llms.mdx/docs/[...slug]/route.ts`), a hairline, the title and lede, another hairline, then the body, then "Last updated" (from `lastCommitDate`) and an edit link above Fumadocs' previous/next cards. Search (`components/search.tsx`, index from `app/api/search/route.ts`) covers every page.
- **Docs styling:** every docs rule lives in `app/docs/docs.css`, imported only by the docs layout and scoped to `.ww-docs` (the layout root), so landing pages never load it. It re-derives Fumadocs' `--color-fd-*` palette from the `--ds-*` tokens and keeps colors, radii, shadows and durations on tokens. `global.css` holds only shared and landing styles; don't add docs rules there, and check new docs class names against `global.css` and `app/(home)` (the landing already owns names such as `.ww-home-hero`).
- **Docs patterns:** `lib/rehype-docs.ts` (wired in `source.config.ts`) renders recurring MDX patterns without special markup: a bold `**Settings → Pane → Control**` becomes a path chip, troubleshooting `**Message:**` / `**Why:**` / `**Fix:**` paragraphs become one definition list, and ```mermaid fences become the client `Mermaid` component (`components/docs/mermaid.tsx`, themed from tokens). They run after remark, so llms.txt and search keep the plain source. Write UI paths as one bold run of plain text with spaces around each arrow.
- **Docs home:** `content/docs/index.mdx` is a normal docs page laid out like Ghostty's: the standard title and lede (the frontmatter description says what WolfWave is), a **Get started** line with two quiet buttons (Download, Build from source: title-only `Card`s inside `<Cards className="ww-buttons">`), a hairline, then four **Featured docs** cards. `page.tsx` drops the breadcrumb row for it (the root has no trail and no Markdown export) and its TOC. It uses only Fumadocs components plus that one class. Keep it this short: the sidebar and the top bar's search already reach every page, so a hero, link grids, or a sponsor block only make it busier (sponsors live on Help & Support).

- **Public pages:** `/changelog/` shares the existing MDX release source but excludes Unreleased sections before compilation (including search, TOC, LLM exports, and OG summaries). `/docs/changelog/` remains a noindex compatibility page with the public canonical. `/design-system/` is the visual showcase; `/docs/design-system/` remains the contributor reference. Showcase values come directly from `design-system/tokens.json`.
- **Web typography:** Montserrat headings, Roboto body, JetBrains Mono code follow the MrDemonWolf website reference. `app/layout.tsx` self-hosts them through `next/font`; `global.css` uses those variables with generated token fallbacks. Web sizes are additive `webSmall`, `webBody`, `webSection`, `webHero` tokens so native control sizes remain independent. Text token pairs target AAA on matching solid surfaces; components and transparent scenes need their own checks.
- **Shared layout:** Long-form pages use `app/docs/[[...slug]]/page.tsx` and Fumadocs. Keep typography, prose rhythm, and mobile navigation in `app/docs/docs.css`; avoid per-page spacing overrides. Prose rules skip `.not-prose` content, so components keep their own styling.
- **Spacing:** Body copy stays left-aligned with a `1.7` line height in a centered reading column of about 75 characters (`--ww-measure`). Keep page descriptions close to their first MDX block; account for spacing already supplied by Fumadocs before adding margins. Use screenshots to check the relationship between each page title, description, first paragraph, and first section heading.
- **Review flow:** Inspect the landing page, `/download/`, `/docs/`, and representative paragraph-first and heading-first docs pages at desktop (`1280×720`) and mobile (`390×844`). Sweep every MDX route at the mobile width for horizontal overflow because all routes share the same layout. Keep review reports temporary when the user asks to remove review notes.
- **Current download path:** The landing hero and closing CTA use `getLatestDmgUrl()` for the primary direct `.dmg` action; the secondary hero action goes to `/download/`. The download page offers the latest `.dmg` and Homebrew command. Keep the macOS 26+ and Apple Silicon requirements visible next to those actions. On phones and touch-first screens (below the `sm` breakpoint, or `hover: none` with `pointer: coarse`) the hero, the closing CTA, and the `/download` hero swap the `.dmg` primary for **Send to my Mac** (`SendToMac`: a real `mailto:` link to the absolute `/download/` URL that upgrades to `navigator.share` once hydrated), because a phone can't install a `.dmg`. The swap is CSS-only (`.ww-cta-desktop` / `.ww-cta-phone` / `.ww-phone-only`), so the static export ships one markup for everyone; desktop is unchanged.
- **Landing preview:** The hero’s single now-playing product window is `_widgets/HeroPlayer.tsx` (`.ww-product-window`) and shares `useCyclingTrack` with the demos further down the page. The other interactive demos live in `_widgets/` (`DiscordPresenceCard`, `OBSOverlayWidget`, `TwitchChatPreview`, and `ComparisonTable`).

### Landing page (`app/(home)`)

The marketing home is `app/(home)/page.tsx`, an **async server component** resolving the latest download and release at build time through `lib/site.ts`. It has five focused sections: one product hero, core features, the interactive overlay, six common questions, and the closing download action. Detailed commands, comparison, privacy, and developer guides stay in the docs. Keep the hero to one preview with a quiet install-options link.

- **Section spine.** Preserve `audiences` (01, core features), `overlay` (02), `faq` (03), and `cta`. Earlier anchors remain as feature-card IDs or zero-height aliases near the features so shared links still resolve. The navbar is Features → Changelog → Docs; Download is a separate action. Supporting links stay in the footer.
- **Motion.** `_widgets/ScrollMotion.tsx` observes explicitly marked heading groups, cards, and previews without animating nested containers. A restrained entrance moves each block 6px over 280ms when it enters the readable viewport, replaying after it leaves and returns. Content is never hidden; reduced-motion changes cancel animations and disconnect observation. `ScrollMotion.test.ts` guards entry, preference changes, and cleanup. Do not restore the short CSS view-timeline effect that completed before readers could notice it.
- **Widgets.** The page renders `HeroPlayer` and `OBSOverlayWidget`, sharing `useCyclingTrack`. `DiscordPresenceCard`, `TwitchChatPreview`, and `ComparisonTable` remain reusable widgets outside the current landing composition. `SendToMac` provides the phone download action. `AlbumArt` and `sample-tracks.ts` provide invented demo content. The timer runs only while a widget is visible and reduced motion permits it. The hero pause button freezes the shared demos and releases its pause when unmounted.
- **FAQ.** `lib/faq.tsx` feeds the six visible answers and homepage `FAQPage` JSON-LD. `content/docs/faq.mdx` is the longer, grouped support reference. Keep visible and structured answers aligned; verify Twitch API eligibility separately from dashboard access.
- **Demo truthfulness.** Every simulated widget has a visible fictional/demo caption. Never use real artist names, songs, viewers, or album art as sample data.
- **Styling** uses `ww-*` utility classes in `app/global.css` (`ww-kicker`, `ww-stat`, `ww-proof`, `ww-chip`, `ww-card`, `ww-glass`, `ww-btn`, `ww-pill`, `ww-to-top`). Reuse these instead of one-off styles. Brand color tokens (`--brand-*`, `--bg-*`, `--txt-*`, `--hairline`) flip per theme.
- **Apple corner geometry.** Rounded surfaces opt into `corner-shape: squircle` (Apple's continuous superellipse) via an `@supports` block; Chromium renders the true squircle, every other browser falls back to the existing `border-radius`. The app-icon squircle uses Apple's **22.37%** ratio. Capsule/pill controls keep true-capsule ends; do **not** squircle them.
- **Flat by default.** Resting elements are flat; defined by a hairline border (and optional *subtle* shadow), never by bevels or float. No inset white highlights, no glassy `::before` sheen, no heavy multi-layer drop shadows. `.ww-glass` is a flat frosted card (frost + border only). Keep drop shadows shallow (e.g. `0 8-10px 24-28px -16px` at low alpha). **Hover-lifts are fine** (subtle `translateY` + brand-tinted shadow on `:hover` only). The OG image (`og-card.tsx`) is a rendered social card, not an on-page element, so it keeps real depth; don't flatten it.
- **Mobile gutters.** Sections use `px-[10%] md:px-6` → content is ~80% width (centered) on phones/tablets, reverting to the `max-w-*` cap on desktop. Use this pattern on new sections rather than a fixed `px-6`.
- **Mobile centering.** Section headers and short feature intros center on mobile (`text-center md:text-left`); card bodies and docs long-form stay left-aligned for readability.

### SEO & Open Graph images

The docs site generates Open Graph / Twitter card images at build time. Both paths are wired so changing page copy updates the social card. Do **not** hand-edit generated PNGs.

**Per-page docs cards (automatic).** Each MDX file under `content/docs/` drives its own card via `apps/docs/app/og/docs/[...slug]/route.tsx`, which reads these optional frontmatter fields and falls back to a section preset in `apps/docs/app/og/_components/og-presets.ts`:

| Frontmatter field | Card slot | Fallback |
|---|---|---|
| `ogTitle` | headline | `title` |
| `ogDescription` | sub-line | `description` |
| `ogEyebrow` | pill | preset by first slug segment |
| `ogChips` | chip row | preset by first slug segment |
| `keywords` | `<meta keywords>` | none |
| `metaTitle` | `<title>` only: search-intent wording ("Install on Mac: DMG, Homebrew & Setup Wizard"), never shown on the page or in the sidebar | `title` |

The changelog page is special-cased: its card is built from the latest `## vX.Y.Z` block in `changelog.mdx`, not from chips. The shared card visual lives in `apps/docs/app/og/_components/og-card.tsx` (`OgCard` + `ChangelogOgCard`).

> `OgCard` renders its headline **one word per flex item** so Satori wraps on word boundaries instead of clipping a single long flex child; don't collapse it back to one text node. Long descriptions are truncated (~120 chars) so the chip row never falls off the 1200×630 frame, and the body is top-aligned so a tall block can't overflow up into the wordmark header.

**Homepage / root card (single source of truth).** Homepage social copy lives in one constant, `homepageSeo` in `apps/docs/lib/site.ts`. It feeds `app/layout.tsx` (root meta + JSON-LD), `app/(home)/page.tsx` (homepage meta), `app/opengraph-image.tsx`, and `app/twitter-image.tsx`. Edit `homepageSeo` once and the meta tags plus both images update on the next build.

**The rule when you touch SEO or visible copy:**

- Changed a docs page's title, description, or pitch: update that page's frontmatter (`ogTitle` / `ogDescription` / `ogChips` / `keywords`) so its card matches.
- Changed the homepage or landing pitch: edit `homepageSeo` in `lib/site.ts`. Never hardcode homepage strings back into `layout.tsx`, `opengraph-image.tsx`, or `twitter-image.tsx`.
- Added a new docs page: start from the frontmatter template below so the card and SEO match the rest of the site.
- Page URLs in metadata (canonical, `og:url`, JSON-LD, the sitemap) go through `pageUrl()`: absolute, trailing slash, base path included. `absoluteUrl()` is for assets. The root layout deliberately sets no canonical or `og:url`, because every route would inherit the homepage's; each page sets its own. A title that already names WolfWave uses `title.absolute` so the root template doesn't brand it twice.

**Structured data** lives in `apps/docs/lib/seo.ts` and is emitted per page, never from the root layout (a docs page or the 404 must not claim to be the app). Home: `WebSite` + `Organization` + `SoftwareApplication` in one `@graph`, plus the `FAQPage` from `lib/faq.tsx`. Download: the same `SoftwareApplication`. Docs: `TechArticle` (git-derived `dateModified`) + a Home › Docs › Page `BreadcrumbList`. Do **not** add `HowTo` (Google retired that rich result) or a `FAQPage` whose questions are not visible on that page, and never invent a rating or review for `SoftwareApplication`. A docs `<title>` that already says "WolfWave" goes out as `title.absolute`, so the template never brands it twice.

**New-page frontmatter template:**

```yaml
---
title: Short page title
description: One-sentence search snippet, around 150 chars, keyword-rich.
ogTitle: Card headline (defaults to title)
ogDescription: Card sub-line (defaults to description)
ogEyebrow: Small pill label
ogChips:
  - Three
  - Or four
  - Short
  - Chips
keywords:
  - primary long-tail phrase
  - secondary phrase
---
```

**OG image standards (what a good card follows):**

- 1200x630 px (1.91:1). This is `OG_SIZE`; do not change it.
- Keep total weight well under 8 MB. Text cards from `next/og` are tiny, so no action needed unless you embed heavy raster art.
- Leave roughly 60 px of breathing room around key text. X, iMessage, and Discord crop the frame differently, so center-weight the message.
- One headline plus three or four chips. High contrast, large type, no paragraphs.
- Use absolute image URLs (`absoluteUrl(...)`; `metadataBase` is set) and `twitter:card = summary_large_image`.
- Give every image real `alt` text.

**Validate after a change:**

1. `bun run build --filter docs`. The OG routes are `force-static`, so they build here and fail the build on a code error.
2. `bun run --filter docs test`. Runs the SEO guard (`apps/docs/lib/seo.test.ts`) over the built `out/`: one `<h1>`, a unique title of at most 65 characters naming WolfWave once, a unique 50-160 character description, a canonical equal to the page's own trailing-slash URL, full OG/Twitter tags with a 1200x630 image, valid JSON-LD of the right types, a noindex 404, and a sitemap listing exactly the indexable pages. The CI `docs` job runs it after the build.
3. Eyeball the PNGs locally (`bun run dev --filter docs`): `/opengraph-image.png`, `/twitter-image.png`, and a page card such as `/og/docs/installation/image.png`.
4. After deploy, re-scrape with opengraph.xyz, the Facebook Sharing Debugger, the X Card Validator, and the LinkedIn Post Inspector. Social platforms cache cards hard, so a rebuild alone will not refresh what people already saw.
