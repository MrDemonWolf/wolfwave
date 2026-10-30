/**
 * Rehype plugins that give recurring docs patterns their designed look
 * without any special markup in the MDX. They run after remark, so the
 * processed markdown behind llms.txt and the search index still holds the
 * plain source. Wired up in `source.config.ts`; styled in `app/docs/docs.css`.
 *
 * - `rehypeMermaid`: ```mermaid fences become a `<Mermaid chart>` component.
 * - `rehypeUiPaths`: bold UI paths like **Settings → Twitch → Bot Commands**
 *   become a path chip, keeping the arrows as real text.
 * - `rehypeIssueBlocks`: troubleshooting **Message:** / **Why:** / **Fix:**
 *   paragraphs become one definition list per problem.
 */

/** The slice of the hast shape these plugins touch. */
export interface HastNode {
  type: string;
  tagName?: string;
  value?: string;
  name?: string;
  properties?: Record<string, unknown>;
  attributes?: unknown[];
  children?: HastNode[];
}

const element = (tagName: string, properties: Record<string, unknown>, children: HastNode[]): HastNode => ({
  type: "element",
  tagName,
  properties,
  children,
});
const text = (value: string): HastNode => ({ type: "text", value });

function textContent(node: HastNode): string {
  if (node.type === "text") return node.value ?? "";
  return (node.children ?? []).map(textContent).join("");
}

function classList(node: HastNode): string[] {
  const value = node.properties?.className;
  if (Array.isArray(value)) return value.map(String);
  return typeof value === "string" ? value.split(/\s+/) : [];
}

function walk(node: HastNode, visit: (node: HastNode) => void) {
  visit(node);
  for (const child of node.children ?? []) walk(child, visit);
}

// ── Mermaid ────────────────────────────────────────────────

/** Runs before Shiki, so the fence never becomes a highlighted code block. */
export function rehypeMermaid() {
  return (tree: HastNode) => {
    walk(tree, (node) => {
      if (!node.children) return;
      node.children = node.children.map((child) => {
        const code = child.tagName === "pre" ? child.children?.find((inner) => inner.tagName === "code") : undefined;
        if (!code || !classList(code).includes("language-mermaid")) return child;
        return {
          type: "mdxJsxFlowElement",
          name: "Mermaid",
          attributes: [{ type: "mdxJsxAttribute", name: "chart", value: textContent(code).trim() }],
          children: [],
        };
      });
    });
  };
}

// ── UI paths ───────────────────────────────────────────────

const PATH_SEPARATOR = " → ";

/** Bold text made only of `→`-separated segments, like "Settings → General". */
export function rehypeUiPaths() {
  return (tree: HastNode) => {
    walk(tree, (node) => {
      if (node.tagName !== "strong") return;
      const children = node.children ?? [];
      if (children.length !== 1 || children[0].type !== "text") return;
      const segments = (children[0].value ?? "").split(PATH_SEPARATOR);
      if (segments.length < 2 || segments.some((segment) => segment.trim() === "" || segment.includes("→"))) return;

      const isSettings = /^(System )?Settings$/.test(segments[0].trim());
      node.properties = { ...node.properties, className: ["ww-path"], ...(isSettings ? { "data-settings": "" } : {}) };
      node.children = segments.flatMap((segment, index) => [
        ...(index > 0 ? [element("span", { className: ["ww-path-sep"] }, [text(" → ")])] : []),
        element("span", { className: ["ww-path-segment"] }, [text(segment)]),
      ]);
    });
  };
}

// ── Troubleshooting issue blocks ───────────────────────────

const ISSUE_LABELS = new Set(["Message", "Why", "Fix"]);

/** The label of a `<p><strong>Message:</strong> …</p>` paragraph, if it is one. */
function issueLabel(node: HastNode): string | undefined {
  if (node.tagName !== "p") return undefined;
  const first = node.children?.[0];
  if (first?.tagName !== "strong") return undefined;
  const label = textContent(first).trim().replace(/:$/, "");
  return ISSUE_LABELS.has(label) && textContent(first).trim().endsWith(":") ? label : undefined;
}

const isBlank = (node: HastNode) => node.type === "text" && (node.value ?? "").trim() === "";

/**
 * Groups each run of labeled paragraphs (and a list or table right after one,
 * such as numbered fix steps) into `<dl class="ww-issue">`. Each pair keeps
 * its label as the `<dt>`, so screen readers still hear "Fix" before the fix.
 */
export function rehypeIssueBlocks() {
  return (tree: HastNode) => {
    walk(tree, (parent) => {
      const children = parent.children;
      if (!children || !children.some((child) => issueLabel(child))) return;

      const out: HastNode[] = [];
      let block: HastNode | undefined;
      let lastBody: HastNode[] | undefined;

      for (const child of children) {
        const label = issueLabel(child);
        if (label) {
          if (!block) {
            block = element("dl", { className: ["ww-issue"] }, []);
            out.push(block);
          }
          const body = (child.children ?? []).slice(1);
          if (body[0]?.type === "text") body[0] = text((body[0].value ?? "").replace(/^\s+/, ""));
          lastBody = body.length ? [element("p", {}, body)] : [];
          block.children?.push(
            element("div", { className: ["ww-issue-row"], "data-label": label.toLowerCase() }, [
              element("dt", {}, [text(label)]),
              element("dd", {}, lastBody),
            ]),
          );
          continue;
        }
        if (block && isBlank(child)) continue;
        if (block && lastBody && (child.tagName === "ol" || child.tagName === "ul" || child.tagName === "table")) {
          lastBody.push(child);
          continue;
        }
        block = undefined;
        lastBody = undefined;
        out.push(child);
      }
      parent.children = out;
    });
  };
}
