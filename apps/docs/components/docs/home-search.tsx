"use client";
import { Search } from "lucide-react";
import { useSearchContext } from "fumadocs-ui/contexts/search";

/**
 * The docs home's search field: a button drawn as a field that opens the same
 * search dialog as the top bar and ⌘K. The home's first job is finding an
 * answer, so it gets the full-width version. Renders nothing while search is off.
 */
export function HomeSearch() {
  const { enabled, hotKey, setOpenSearch } = useSearchContext();
  if (!enabled) return null;

  return (
    <button type="button" className="ww-home-search" aria-haspopup="dialog" onClick={() => setOpenSearch(true)}>
      <Search aria-hidden="true" />
      <span className="ww-home-search-label">Search the docs</span>
      {/* The shortcut is a hint for sighted users; the button carries the name. */}
      <span className="ww-home-search-keys" aria-hidden="true">
        {hotKey.map((key, index) => (
          <kbd key={index}>{key.display}</kbd>
        ))}
      </span>
    </button>
  );
}
