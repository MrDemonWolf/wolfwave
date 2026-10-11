"use client";

import { useState } from "react";
import { Check, Send } from "lucide-react";

/**
 * Phone-only primary download action. A phone cannot install a .dmg, so on
 * small or touch screens the landing CTAs swap the .dmg button for this one
 * (the swap itself is pure CSS: `.ww-cta-phone` / `.ww-cta-desktop` in
 * global.css, so the static export renders identical markup everywhere and
 * nothing depends on hydration).
 *
 * It is a real `mailto:` link, so it works before or without JavaScript. Once
 * hydrated, a tap opens the native share sheet instead (AirDrop, Messages,
 * Notes, Mail) when the browser has `navigator.share`. A dismissed sheet does
 * nothing; any other share failure falls back to the mail link.
 */
export function SendToMac({
  url,
  className,
  label = "Send to my Mac",
}: {
  /** Absolute URL of the download page, base path included. */
  url: string;
  className?: string;
  label?: string;
}) {
  const [shared, setShared] = useState(false);
  const subject = "WolfWave for Mac";
  const body = `Download WolfWave on your Mac (macOS 26+, Apple Silicon): ${url}`;
  const mailto = `mailto:?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;

  async function onClick(event: React.MouseEvent<HTMLAnchorElement>) {
    if (typeof navigator === "undefined" || typeof navigator.share !== "function") {
      return; // Let the mailto: link do its job.
    }
    event.preventDefault();
    try {
      await navigator.share({ title: subject, text: "Download WolfWave on your Mac.", url });
      setShared(true);
    } catch (error) {
      // AbortError = the visitor closed the sheet. Respect that.
      if (error instanceof DOMException && error.name === "AbortError") return;
      window.location.href = mailto;
    }
  }

  return (
    <a href={mailto} onClick={onClick} className={className}>
      {shared ? (
        <Check className="w-4 h-4" aria-hidden="true" />
      ) : (
        <Send className="w-4 h-4" aria-hidden="true" />
      )}
      {shared ? "Link sent" : label}
    </a>
  );
}
