/**
 * Shorter sidebar labels, keyed by page URL. A page that isn't listed shows
 * its title. Page order and groups live in `content/docs/meta.json`, and
 * `lib/docs-tree.ts` turns each `---Group---` separator there into a
 * collapsible sidebar folder, so a label never changes a page's `<h1>`,
 * `<title>`, or URL.
 */
export const SIDEBAR_LABELS: Readonly<Record<string, string>> = {
  "/docs/listening-history": "Listening History",
  "/docs/faq": "FAQ",
  "/docs/support": "Help & Support",
  "/docs/comparison": "Compare Alternatives",
  "/docs/acknowledgements": "Acknowledgements",
  "/docs/stream-deck": "Stream Deck Protocol",
  "/docs/design-system": "Overview",
  "/docs/design-system/components": "Components",
};
