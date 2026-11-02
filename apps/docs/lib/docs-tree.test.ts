import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import type * as PageTree from "fumadocs-core/page-tree";
import { SIDEBAR_LABELS } from "./docs-nav";
import { applyLabels, docsTreePlugin, groupForUrl, groupIntoFolders, isFallbackTree } from "./docs-tree";

const meta = JSON.parse(readFileSync(new URL("../content/docs/meta.json", import.meta.url), "utf8")) as {
  pages: string[];
};

const page = (url: string, name = url): PageTree.Item => ({ type: "page", name, url });
const separator = (name: string): PageTree.Separator => ({ type: "separator", name });

function sampleTree(): PageTree.Root {
  return {
    name: "Documentation",
    children: [
      page("/docs", "WolfWave docs"),
      page("/docs/installation", "Install"),
      separator("Help"),
      page("/docs/faq", "Frequently asked questions"),
      separator("Developers"),
      page("/docs/development", "Development"),
    ],
  };
}

const folders = (tree: PageTree.Root) =>
  tree.children.filter((node): node is PageTree.Folder => node.type === "folder");

describe("groupIntoFolders", () => {
  test("keeps the pages before the first group at the top level", () => {
    const tree = groupIntoFolders(sampleTree());
    expect(tree.children.slice(0, 2).map((node) => node.type === "page" && node.url)).toEqual([
      "/docs",
      "/docs/installation",
    ]);
  });

  test("turns each group into a folder of the pages after it, in order", () => {
    const tree = groupIntoFolders(sampleTree());
    expect(folders(tree).map((folder) => folder.name)).toEqual(["Help", "Developers"]);
    expect(folders(tree).map((folder) => folder.children.map((child) => child.type === "page" && child.url))).toEqual([
      ["/docs/faq"],
      ["/docs/development"],
    ]);
  });

  test("leaves no separators behind", () => {
    const tree = groupIntoFolders(sampleTree());
    const nodes = [...tree.children, ...folders(tree).flatMap((folder) => folder.children)];
    expect(nodes.some((node) => node.type === "separator")).toBe(false);
  });

  test("keeps the fallback tree for unlisted pages", () => {
    const tree = sampleTree();
    tree.fallback = { name: "fallback", children: [page("/docs/changelog")] };
    expect(groupIntoFolders(tree).fallback?.children).toHaveLength(1);
  });
});

describe("applyLabels", () => {
  test("shortens listed pages inside folders and leaves the rest alone", () => {
    const tree = applyLabels(groupIntoFolders(sampleTree()), { "/docs/faq": "FAQ" });
    const faq = folders(tree)[0].children[0];
    expect(faq.type === "page" && faq.name).toBe("FAQ");
    const home = tree.children[0];
    expect(home.type === "page" && home.name).toBe("WolfWave docs");
  });
});

describe("groupForUrl", () => {
  test("names a page's group, and none for top-level or unknown pages", () => {
    const tree = groupIntoFolders(sampleTree());
    expect(groupForUrl(tree, "/docs/development")).toBe("Developers");
    expect(groupForUrl(tree, "/docs/installation")).toBeUndefined();
    expect(groupForUrl(tree, "/docs/missing")).toBeUndefined();
  });
});

describe("docsTreePlugin", () => {
  const transform = (root: PageTree.Root) => {
    const hook = docsTreePlugin().transformPageTree?.root;
    if (!hook) throw new Error("the plugin should transform the root");
    // The hook's `this` (the builder context) is unused.
    return hook.call({} as never, root);
  };

  test("folds and labels the main tree", () => {
    const tree = transform({ ...sampleTree(), $id: "root" });
    expect(folders(tree).map((folder) => folder.name)).toEqual(["Help", "Developers"]);
    const faq = folders(tree)[0].children[0];
    expect(faq.type === "page" && faq.name).toBe(SIDEBAR_LABELS["/docs/faq"]);
  });

  test("leaves Fumadocs' fallback tree (unlisted pages) alone", () => {
    const fallback: PageTree.Root = { $id: "fallback:root", name: "Docs", children: [page("/docs/changelog", "Changelog")] };
    expect(isFallbackTree(fallback)).toBe(true);
    expect(transform(fallback)).toBe(fallback);
  });
});

describe("meta.json and the sidebar labels stay in step", () => {
  const urls = meta.pages
    .filter((entry) => !entry.startsWith("---"))
    .map((entry) => {
      const link = entry.match(/^\[.*\]\((.+)\)$/);
      if (link) return link[1];
      const slug = entry.replace(/\/index$/, "").replace(/^index$/, "");
      return slug ? `/docs/${slug}` : "/docs";
    });

  test("every label names a page in meta.json", () => {
    for (const url of Object.keys(SIDEBAR_LABELS)) expect(urls, `${url} is not in meta.json`).toContain(url);
  });

  test("the home comes first, and every group holds at least one page", () => {
    expect(urls[0]).toBe("/docs");
    meta.pages.forEach((entry, index) => {
      if (!entry.startsWith("---")) return;
      const next = meta.pages[index + 1];
      expect(next !== undefined && !next.startsWith("---"), `${entry} has no pages`).toBe(true);
    });
  });
});
