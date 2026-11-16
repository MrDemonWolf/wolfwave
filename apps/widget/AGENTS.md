# AGENTS.md: OBS widget (`apps/widget/`)

> Paths in backticks are relative to the repo root unless they are links. Shared rules (CI, docs sync, versioning, release) are in the root [`AGENTS.md`](../../AGENTS.md).

**OBS widget**: source lives at `apps/widget/`; the bundled
`apps/native/WolfWave/Resources/widget.html` is a **generated artifact**
that is **committed** to the repo. Xcode does **not** rebuild it; the
native build ships the committed file as-is, so contributors who only
touch Swift never need `bun`. If you edit `apps/widget/`, run `make widget`
(or `bun run --filter widget build`) with the pinned Bun from `package.json`
`packageManager`: other Bun releases minify differently, so the drift check fails. If you edit design tokens or their
generator, run `bun run tokens` first, or use the ordered root
`bun run build`. Commit the regenerated `widget.html` (and any token
outputs) with the source change. CI regenerates both layers and fails the
PR on drift. The widget has its own suite (`bun run --filter widget test`,
`apps/widget/tests/`, bun test + happy-dom), which the CI `test` job also runs.
See `apps/widget/README.md` and the
[OBS Widget Architecture](../docs/content/docs/widget.mdx) docs page.

Widget themes and layouts come from design tokens; see [`design-system/AGENTS.md`](../../design-system/AGENTS.md).
