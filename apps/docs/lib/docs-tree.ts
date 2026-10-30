import type * as PageTree from "fumadocs-core/page-tree";
import type { LoaderPlugin } from "fumadocs-core/source";
import type { ReactNode } from "react";
import {
  DOCS_NAV_ENTRIES,
  DOCS_TABS,
  HIDDEN_GROUP_LABELS,
  type DocsNavEntry,
  type DocsTab,
} from "./docs-nav";

/**
 * Builds the tabbed docs sidebar from the flat `meta.json` tree.
 *
 * `meta.json` lists every page in order, split by `---Group---` separators.
 * Each group belongs to one tab (see `DOCS_TABS`). This turns the flat list
 * into one folder per tab, marked as a typed `root`, which is what Fumadocs
 * uses to scope the sidebar to the current tab. Files never move, so URLs,
 * anchors, OG images and every hard-coded `content/docs/*.mdx` path are safe.
 */
export function groupIntoTabs(root: PageTree.Root, tabs: readonly DocsTab[] = DOCS_TABS): PageTree.Root {
  const tabByGroup = new Map<string, DocsTab>();
  for (const tab of tabs) for (const group of tab.groups) tabByGroup.set(group, tab);

  const buckets = new Map<DocsTab["id"], PageTree.Node[]>(tabs.map((tab) => [tab.id, []]));
  let current = tabs[0];

  for (const node of root.children) {
    if (node.type === "separator") {
      const name = typeof node.name === "string" ? node.name : "";
      const tab = tabByGroup.get(name);
      if (!tab) {
        throw new Error(`docs-tree: the meta.json group "${name}" has no tab. Add it to DOCS_TABS in lib/docs-nav.ts.`);
      }
      current = tab;
      if (HIDDEN_GROUP_LABELS.has(name)) continue;
    }
    buckets.get(current.id)?.push(node);
  }

  return {
    ...root,
    children: tabs.map(
      (tab): PageTree.Folder => ({
        type: "folder",
        $id: `tab:${tab.id}`,
        name: tab.title,
        root: tab.id,
        children: buckets.get(tab.id) ?? [],
      }),
    ),
  };
}

/** Applies the sidebar's short labels and icon tiles, keyed by URL. Page titles are untouched. */
export function decorateTree(
  root: PageTree.Root,
  renderIcon: (entry: DocsNavEntry) => ReactNode,
  entries: Readonly<Record<string, DocsNavEntry>> = DOCS_NAV_ENTRIES,
): PageTree.Root {
  const visit = (node: PageTree.Node): PageTree.Node => {
    if (node.type === "folder") return { ...node, children: node.children.map(visit) };
    if (node.type !== "page") return node;
    const entry = entries[node.url];
    if (!entry) return node;
    return { ...node, name: entry.label ?? node.name, icon: renderIcon(entry) };
  };
  return { ...root, children: root.children.map(visit) };
}

/** Which tab a URL lives in (`undefined` for pages outside the sidebar, like the changelog source). */
export function tabIdForUrl(tree: PageTree.Root, url: string): DocsTab["id"] | undefined {
  for (const tab of tree.children) {
    if (tab.type !== "folder" || typeof tab.root !== "string") continue;
    if (containsUrl(tab, url)) return tab.root as DocsTab["id"];
  }
  return undefined;
}

/** The tab and group a page sits in, for the breadcrumb above its title. */
export function docsCrumbs(tree: PageTree.Root, url: string): { tab: DocsTab; group?: string } | undefined {
  const id = tabIdForUrl(tree, url);
  const tab = DOCS_TABS.find((candidate) => candidate.id === id);
  const folder = tree.children.find((node) => node.type === "folder" && node.root === id);
  if (!tab || !folder || folder.type !== "folder") return undefined;

  let group: string | undefined;
  for (const node of folder.children) {
    if (node.type === "separator") group = typeof node.name === "string" ? node.name : undefined;
    else if (node.type === "page" && node.url === url) return { tab, group };
  }
  return { tab };
}

function containsUrl(folder: PageTree.Folder, url: string): boolean {
  if (folder.index?.url === url) return true;
  return folder.children.some((child) =>
    child.type === "folder" ? containsUrl(child, url) : child.type === "page" && child.url === url,
  );
}

/**
 * Loader plugin: groups the tree into tabs, then decorates it. Runs inside
 * `loader()`, so the sidebar, prev/next links, search breadcrumbs and
 * llms.txt all see the same tree.
 *
 * Fumadocs also runs the transform on its fallback tree (pages not listed in
 * meta.json, such as the `/docs/changelog` page old app builds still open).
 * That tree is left as is, so those pages show the whole site in the sidebar
 * rather than a one-page "Guides" tab.
 */
export function docsTabsPlugin(renderIcon: (entry: DocsNavEntry) => ReactNode): LoaderPlugin {
  return {
    name: "wolfwave:docs-tabs",
    transformPageTree: {
      root(root) {
        if (isFallbackTree(root)) return root;
        return decorateTree(groupIntoTabs(root), renderIcon);
      },
    },
  };
}

/** Fumadocs builds the fallback tree with a `fallback` id prefix. */
export function isFallbackTree(root: PageTree.Root): boolean {
  return root.$id?.startsWith("fallback") ?? false;
}
