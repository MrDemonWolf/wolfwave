import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import type * as PageTree from "fumadocs-core/page-tree";
import { DOCS_NAV_ENTRIES, DOCS_TABS, HIDDEN_GROUP_LABELS } from "./docs-nav";
import { decorateTree, docsTabsPlugin, groupIntoTabs, isFallbackTree, tabIdForUrl } from "./docs-tree";

const meta = JSON.parse(readFileSync(new URL("../content/docs/meta.json", import.meta.url), "utf8")) as {
  pages: string[];
};

const page = (url: string, name = url): PageTree.Item => ({ type: "page", name, url });
const separator = (name: string): PageTree.Separator => ({ type: "separator", name });

function sampleTree(): PageTree.Root {
  return {
    name: "Documentation",
    children: [
      page("/docs", "Documentation"),
      separator("Start here"),
      page("/docs/installation", "Install"),
      separator("Contribute"),
      page("/docs/development", "Development"),
      separator("Design System"),
      page("/docs/design-system", "Design System"),
    ],
  };
}

describe("groupIntoTabs", () => {
  test("makes one typed root folder per tab, in tab order", () => {
    const tree = groupIntoTabs(sampleTree());
    expect(tree.children.map((node) => node.type === "folder" && node.root)).toEqual(DOCS_TABS.map((tab) => tab.id));
  });

  test("puts pages before the first separator in the first tab", () => {
    const tree = groupIntoTabs(sampleTree());
    expect(tabIdForUrl(tree, "/docs")).toBe("guides");
    expect(tabIdForUrl(tree, "/docs/installation")).toBe("guides");
    expect(tabIdForUrl(tree, "/docs/development")).toBe("developers");
    expect(tabIdForUrl(tree, "/docs/design-system")).toBe("design-system");
  });

  test("keeps group separators but drops labels that repeat the tab", () => {
    const tree = groupIntoTabs(sampleTree());
    const names = tree.children.flatMap((tab) =>
      tab.type === "folder" ? tab.children.filter((node) => node.type === "separator").map((node) => node.name) : [],
    );
    expect(names).toEqual(["Start here", "Contribute"]);
  });

  test("fails loudly on a group no tab claims", () => {
    const tree = sampleTree();
    tree.children.push(separator("Mystery"), page("/docs/mystery"));
    expect(() => groupIntoTabs(tree)).toThrow(/Mystery/);
  });

  test("keeps the fallback tree for unlisted pages", () => {
    const tree = sampleTree();
    tree.fallback = { name: "fallback", children: [page("/docs/changelog")] };
    expect(groupIntoTabs(tree).fallback?.children).toHaveLength(1);
  });
});

describe("decorateTree", () => {
  test("applies short labels and icons by URL, leaving others alone", () => {
    const tree = decorateTree(groupIntoTabs(sampleTree()), (entry) => entry.tint);
    const guides = tree.children[0];
    if (guides.type !== "folder") throw new Error("expected the guides folder");
    const home = guides.children[0];
    expect(home.type === "page" && home.name).toBe("Overview");
    expect(home.type === "page" && home.icon).toBe("brand");
  });
});

describe("docsTabsPlugin", () => {
  const transform = (root: PageTree.Root) => {
    const hook = docsTabsPlugin((entry) => entry.tint).transformPageTree?.root;
    if (!hook) throw new Error("the plugin should transform the root");
    // The hook's `this` (the builder context) is unused.
    return hook.call({} as never, root);
  };

  test("tabs and decorates the main tree", () => {
    const tree = transform({ ...sampleTree(), $id: "root" });
    expect(tree.children.map((node) => node.type === "folder" && node.root)).toEqual(DOCS_TABS.map((tab) => tab.id));
  });

  test("leaves Fumadocs' fallback tree (unlisted pages) alone", () => {
    const fallback: PageTree.Root = { $id: "fallback:root", name: "Docs", children: [page("/docs/changelog", "Changelog")] };
    expect(isFallbackTree(fallback)).toBe(true);
    expect(transform(fallback)).toBe(fallback);
  });
});

describe("meta.json and docs-nav stay in step", () => {
  const groups = meta.pages.filter((entry) => entry.startsWith("---")).map((entry) => entry.slice(3, -3));

  test("every meta.json group belongs to exactly one tab", () => {
    for (const group of groups) {
      expect(DOCS_TABS.filter((tab) => tab.groups.includes(group))).toHaveLength(1);
    }
  });

  test("every tab group exists in meta.json", () => {
    for (const tab of DOCS_TABS) for (const group of tab.groups) expect(groups).toContain(group);
  });

  test("hidden labels name real groups", () => {
    for (const group of HIDDEN_GROUP_LABELS) expect(groups).toContain(group);
  });

  test("every sidebar page and link has an icon tile", () => {
    const urls = meta.pages
      .filter((entry) => !entry.startsWith("---"))
      .map((entry) => {
        const link = entry.match(/^\[.*\]\((.+)\)$/);
        if (link) return link[1];
        const slug = entry.replace(/\/index$/, "").replace(/^index$/, "");
        return slug ? `/docs/${slug}` : "/docs";
      });
    for (const url of urls) expect(DOCS_NAV_ENTRIES[url], `${url} needs an entry in DOCS_NAV_ENTRIES`).toBeDefined();
    for (const url of Object.keys(DOCS_NAV_ENTRIES)) expect(urls, `${url} is not in meta.json`).toContain(url);
  });

  test("each tab's switcher URL is a page in that tab", () => {
    const urls = new Map<string, string>();
    let tab = DOCS_TABS[0].id as string;
    for (const entry of meta.pages) {
      if (entry.startsWith("---")) {
        tab = DOCS_TABS.find((candidate) => candidate.groups.includes(entry.slice(3, -3)))?.id ?? tab;
        continue;
      }
      const slug = entry.replace(/\/index$/, "").replace(/^index$/, "");
      urls.set(slug ? `/docs/${slug}` : "/docs", tab);
    }
    for (const candidate of DOCS_TABS) expect(urls.get(candidate.url)).toBe(candidate.id);
  });
});
