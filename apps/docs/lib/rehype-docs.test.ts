import { describe, expect, test } from "bun:test";
import { type HastNode, rehypeIssueBlocks, rehypeMermaid, rehypeUiPaths } from "./rehype-docs";

const el = (tagName: string, children: HastNode[] = [], properties: Record<string, unknown> = {}): HastNode => ({
  type: "element",
  tagName,
  properties,
  children,
});
const txt = (value: string): HastNode => ({ type: "text", value });
const root = (...children: HastNode[]): HastNode => ({ type: "root", children });

function text(node: HastNode): string {
  if (node.type === "text") return node.value ?? "";
  return (node.children ?? []).map(text).join("");
}

describe("rehypeMermaid", () => {
  test("turns a mermaid fence into a Mermaid element with the chart source", () => {
    const tree = root(el("pre", [el("code", [txt("flowchart LR\n  A --> B\n")], { className: ["language-mermaid"] })]));
    rehypeMermaid()(tree);
    const node = tree.children?.[0];
    expect(node?.type).toBe("mdxJsxFlowElement");
    expect(node?.name).toBe("Mermaid");
    expect(node?.attributes).toEqual([{ type: "mdxJsxAttribute", name: "chart", value: "flowchart LR\n  A --> B" }]);
  });

  test("leaves other code blocks alone", () => {
    const pre = el("pre", [el("code", [txt("make build")], { className: ["language-bash"] })]);
    const tree = root(pre);
    rehypeMermaid()(tree);
    expect(tree.children?.[0]).toBe(pre);
  });
});

describe("rehypeUiPaths", () => {
  test("splits a bold Settings path into segments and keeps the arrows as text", () => {
    const strong = el("strong", [txt("Settings → Twitch → Bot Commands")]);
    rehypeUiPaths()(root(el("p", [strong])));
    expect(strong.properties?.className).toEqual(["ww-path"]);
    expect("data-settings" in (strong.properties ?? {})).toBe(true);
    expect(text(strong)).toBe("Settings → Twitch → Bot Commands");
    expect(strong.children?.filter((child) => child.properties?.className?.toString() === "ww-path-segment")).toHaveLength(3);
  });

  test("marks other app paths without the Settings icon", () => {
    const strong = el("strong", [txt("Music → Settings → General")]);
    rehypeUiPaths()(root(strong));
    expect(strong.properties?.className).toEqual(["ww-path"]);
    expect("data-settings" in (strong.properties ?? {})).toBe(false);
  });

  test("ignores ordinary bold text and mixed content", () => {
    const plain = el("strong", [txt("Join Channel")]);
    const mixed = el("strong", [txt("Settings → "), el("code", [txt("!song")])]);
    const dangling = el("strong", [txt("Settings → ")]);
    rehypeUiPaths()(root(plain, mixed, dangling));
    for (const node of [plain, mixed, dangling]) expect(node.properties?.className).toBeUndefined();
  });
});

describe("rehypeIssueBlocks", () => {
  const labeled = (label: string, body: string) => el("p", [el("strong", [txt(`${label}:`)]), txt(` ${body}`)]);

  test("groups Message / Why / Fix into one definition list", () => {
    const tree = root(
      el("h3", [txt("Sign-in expired")]),
      txt("\n"),
      labeled("Message", '"Twitch sign-in expired."'),
      txt("\n"),
      labeled("Why", "The refresh failed."),
      txt("\n"),
      labeled("Fix", "Click Reconnect with Twitch."),
      el("p", [txt("Unrelated paragraph.")]),
    );
    rehypeIssueBlocks()(tree);
    const [heading, list, after] = (tree.children ?? []).filter((node) => node.type !== "text");
    expect(heading.tagName).toBe("h3");
    expect(list.tagName).toBe("dl");
    expect(list.children?.map((row) => row.properties?.["data-label"])).toEqual(["message", "why", "fix"]);
    expect(text(list.children?.[2] ?? txt(""))).toBe("FixClick Reconnect with Twitch.");
    expect(after.tagName).toBe("p");
  });

  test("keeps numbered fix steps inside the Fix row", () => {
    const steps = el("ol", [el("li", [txt("Turn Stream Widgets off.")])]);
    const tree = root(labeled("Why", "Another app has the port."), labeled("Fix", "Pick a new port:"), steps);
    rehypeIssueBlocks()(tree);
    const list = tree.children?.[0];
    expect(tree.children).toHaveLength(1);
    const fixBody = list?.children?.[1]?.children?.[1];
    expect(fixBody?.tagName).toBe("dd");
    expect(fixBody?.children?.at(-1)).toBe(steps);
  });

  test("leaves bold labels without a colon alone", () => {
    const paragraph = el("p", [el("strong", [txt("Fix")]), txt(" the overlay.")]);
    const tree = root(paragraph);
    rehypeIssueBlocks()(tree);
    expect(tree.children?.[0]).toBe(paragraph);
  });
});
