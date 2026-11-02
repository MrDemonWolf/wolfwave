import type * as PageTree from "fumadocs-core/page-tree";
import type { LoaderPlugin } from "fumadocs-core/source";
import { SIDEBAR_LABELS } from "./docs-nav";

/**
 * Builds the docs sidebar from the flat `meta.json` tree.
 *
 * `meta.json` lists every page in order. Pages before the first `---Group---`
 * separator (the home, Install, Features) stay at the top of the sidebar, and
 * each separator becomes a collapsible folder holding the pages after it.
 * Files never move, so URLs, anchors, OG images and every hard-coded
 * `content/docs/*.mdx` path are safe.
 */
export function groupIntoFolders(root: PageTree.Root): PageTree.Root {
  const children: PageTree.Node[] = [];
  let folder: PageTree.Folder | undefined;

  for (const node of root.children) {
    if (node.type === "separator") {
      const name = typeof node.name === "string" ? node.name : "";
      folder = { type: "folder", $id: `group:${name}`, name, children: [] };
      children.push(folder);
      continue;
    }
    (folder?.children ?? children).push(node);
  }

  return { ...root, children };
}

/** Applies the sidebar's shorter labels, keyed by URL. Page titles are untouched. */
export function applyLabels(
  root: PageTree.Root,
  labels: Readonly<Record<string, string>> = SIDEBAR_LABELS,
): PageTree.Root {
  const visit = (node: PageTree.Node): PageTree.Node => {
    if (node.type === "folder") return { ...node, children: node.children.map(visit) };
    if (node.type !== "page") return node;
    const label = labels[node.url];
    return label ? { ...node, name: label } : node;
  };
  return { ...root, children: root.children.map(visit) };
}

/** The sidebar group a page sits in, for the breadcrumb above its title. Top-level pages have none. */
export function groupForUrl(tree: PageTree.Root, url: string): string | undefined {
  for (const node of tree.children) {
    if (node.type !== "folder") continue;
    if (node.children.some((child) => child.type === "page" && child.url === url)) {
      return typeof node.name === "string" ? node.name : undefined;
    }
  }
  return undefined;
}

/**
 * Loader plugin: folds the groups into folders, then applies the labels. Runs
 * inside `loader()`, so the sidebar, prev/next links, search breadcrumbs and
 * llms.txt all see the same tree.
 *
 * Fumadocs also runs the transform on its fallback tree (pages not listed in
 * meta.json, such as the `/docs/changelog` page old app builds still open).
 * That tree has no groups, so it is left as is.
 */
export function docsTreePlugin(): LoaderPlugin {
  return {
    name: "wolfwave:docs-tree",
    transformPageTree: {
      root(root) {
        if (isFallbackTree(root)) return root;
        return applyLabels(groupIntoFolders(root));
      },
    },
  };
}

/** Fumadocs builds the fallback tree with a `fallback` id prefix. */
export function isFallbackTree(root: PageTree.Root): boolean {
  return root.$id?.startsWith("fallback") ?? false;
}
