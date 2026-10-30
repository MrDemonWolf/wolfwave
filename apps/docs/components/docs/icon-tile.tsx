import type { LucideIcon } from "lucide-react";
import type { TileTint } from "@/lib/docs-nav";

/**
 * A small rounded color tile with a white glyph, like the icons in the macOS
 * System Settings sidebar. Decorative: the label beside it carries the meaning.
 * Colors come from `[data-tint]` rules in `app/docs/docs.css`.
 */
export function IconTile({ icon: Icon, tint }: { icon: LucideIcon; tint: TileTint }) {
  return (
    <span className="ww-tile" data-tint={tint} aria-hidden="true">
      <Icon strokeWidth={2.25} />
    </span>
  );
}
