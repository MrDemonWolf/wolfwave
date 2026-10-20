import { replaceSource } from 'fumadocs-core/mdx-plugins/stringifier';

interface Node {
  type: string;
  depth?: number;
  value?: string;
  children?: Node[];
}

/** Remove draft release sections before MDX, search, TOC, and markdown exports are generated. */
export function remarkReleasedChangelog() {
  return (tree: { children: Node[] }, file: { path?: string }) => {
    if (!file.path?.replaceAll('\\', '/').endsWith('/changelog.mdx')) return;
    let hidden = false;
    tree.children = tree.children.filter((node) => {
      if (node.type === 'heading' && node.depth === 2) {
        const text = (node.children ?? []).map((child) => child.value ?? '').join('');
        hidden = /\bunreleased\b/i.test(text);
      }
      // Fumadocs also exports authored source, independent of the filtered AST.
      if (hidden) replaceSource(file as Parameters<typeof replaceSource>[0], node as Parameters<typeof replaceSource>[1], '');
      return !hidden;
    });
  };
}
