import { source } from "@/lib/source";
import { DocsLayout } from "fumadocs-ui/layouts/notebook";
import { baseOptions } from "@/lib/layout.shared";
import { DocsHeader } from "@/components/docs/docs-header";
import { DocsTabs } from "@/components/docs/docs-tabs";
import "./docs.css";

/**
 * Docs shell for everything under `/docs`: the Notebook layout with a
 * full-width top bar that matches the landing navbar, and a sidebar scoped to
 * the current tab (Guides, Developers, Design). Tabs come from the page tree
 * (`lib/docs-tree.ts`), so Fumadocs' own tab dropdown is turned off in favour
 * of `DocsTabs`. `.ww-docs` scopes every rule in `./docs.css`, which only
 * docs routes load.
 */
export default function Layout({ children }: LayoutProps<"/docs">) {
  const options = baseOptions();
  return (
    <DocsLayout
      tree={source.getPageTree()}
      {...options}
      nav={{ ...options.nav, mode: "top", transparentMode: "none" }}
      tabs={false}
      sidebar={{ banner: <DocsTabs />, collapsible: false }}
      slots={{ header: DocsHeader }}
      containerProps={{ className: "ww-docs" }}
    >
      {children}
    </DocsLayout>
  );
}
