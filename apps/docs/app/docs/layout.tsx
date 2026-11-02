import { source } from "@/lib/source";
import { DocsLayout } from "fumadocs-ui/layouts/notebook";
import { baseOptions } from "@/lib/layout.shared";
import { DocsHeader } from "@/components/docs/docs-header";
import "./docs.css";

/**
 * Docs shell for everything under `/docs`: the Notebook layout with a
 * full-width top bar that matches the landing navbar, and one plain sidebar.
 * The home, Install and Features sit on top, then a collapsible folder per
 * meta.json group (`lib/docs-tree.ts`). `.ww-docs` scopes every rule in
 * `./docs.css`, which only docs routes load.
 */
export default function Layout({ children }: LayoutProps<"/docs">) {
  const options = baseOptions();
  return (
    <DocsLayout
      tree={source.getPageTree()}
      {...options}
      nav={{ ...options.nav, mode: "top", transparentMode: "none" }}
      tabs={false}
      sidebar={{ collapsible: false }}
      slots={{ header: DocsHeader }}
      containerProps={{ className: "ww-docs" }}
    >
      {children}
    </DocsLayout>
  );
}
