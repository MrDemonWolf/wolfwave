# WolfWave Docs Site

The public documentation site for WolfWave at
[wolfwave.mrdemonwolf.dev](https://wolfwave.mrdemonwolf.dev).
This is a Next.js app powered by [Fumadocs](https://fumadocs.dev) with
static export, deployed to GitHub Pages by `.github/workflows/docs.yml`.

For the product itself, see the [root README](../../README.md).

## Run locally

From the repo root:

```bash
bun install
bun run dev --filter docs
```

Open <http://localhost:3000>.

## Layout

| Path | What it is |
| --- | --- |
| `app/(home)` | Landing page and download page. |
| `app/docs` | Documentation layout (Fumadocs Notebook, top bar plus tabbed sidebar) and the page template. `app/docs/docs.css` holds every docs style, scoped to the docs layout. |
| `app/api/search/route.ts` | Static search index, tagged by sidebar tab. |
| `app/llms.mdx/docs/[...slug]/route.ts` | One static markdown file per page, for the Copy Markdown button. |
| `content/docs/` | All MDX content. Page order and groups are in `content/docs/meta.json`. |
| `lib/docs-nav.ts` + `lib/docs-tree.ts` | Which groups make up the Guides, Developers and Design tabs, each page's sidebar icon tile, and the loader plugin that builds the tabbed sidebar. |
| `lib/rehype-docs.ts` | UI path chips, troubleshooting Message / Why / Fix lists, and Mermaid diagrams, all from plain MDX. |
| `components/docs/` | Docs header, tab switcher, icon tiles, Mermaid, and the docs home blocks. |
| `app/global.css` + `app/tokens.generated.css` | Shared and landing styling. Generated CSS comes from `design-system/tokens.json`; do not edit by hand. |

Adding a page? See [Edit the docs site](https://wolfwave.mrdemonwolf.dev/docs/development/#edit-the-docs-site).

## Build

```bash
bun run build --filter docs
```

Outputs a static export to `apps/docs/out/`.

## Custom domain

GitHub Pages serves `https://wolfwave.mrdemonwolf.dev/` from the domain root.
`NEXT_PUBLIC_BASE_PATH` defaults to an empty string, and the deployment workflow
sets it explicitly. Keep `lib/site.ts`, `lib/utils.ts`, and `next.config.mjs` in
sync when changing deployment paths. Canonical URLs, the sitemap, robots, LLM
exports, and social images derive their absolute URLs from `lib/site.ts`.

DNS uses a DNS-only CNAME from `wolfwave` to `mrdemonwolf.github.io`. Configure the
custom domain and Enforce HTTPS in repository Settings → Pages. GitHub handles
redirects from the previous project URL. The Homebrew cask lives in the separate
`MrDemonWolf/homebrew-den` repository; keep its homepage aligned with this domain.
