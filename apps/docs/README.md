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
| `app/docs` | Documentation layout. Fumadocs renders the MDX from `content/docs/`. |
| `app/api/search/route.ts` | Static search index. |
| `content/docs/` | All MDX content. Sidebar order is in `content/docs/meta.json`. |
| `app/global.css` + `app/tokens.generated.css` | Token-driven styling. Generated CSS comes from `design-system/tokens.json`; do not edit by hand. |

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
