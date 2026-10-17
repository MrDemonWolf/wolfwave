import type { Metadata } from "next";
import Link from "next/link";
import { NotFoundRedirect } from "./not-found-redirect";

/**
 * Static-export 404 page. Server component so it can carry metadata. The
 * exported 404.html is served at whatever URL missed, so it must never be
 * indexed: Next injects `<meta name="robots" content="noindex">` on not-found
 * output by itself (verified in out/404.html), and the root layout no longer
 * sets a site-wide canonical for it to inherit. The moved-slug redirect runs
 * client-side in {@link NotFoundRedirect}.
 */
export const metadata: Metadata = {
  title: "Page not found",
  // Its own description, so a shared broken link does not preview as the homepage.
  description: "This WolfWave page does not exist or has moved. Try the docs home.",
};

export default function NotFound() {
  return (
    <main
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: "0.75rem",
        minHeight: "60vh",
        textAlign: "center",
        padding: "2rem",
      }}
    >
      <NotFoundRedirect />
      <h1 style={{ fontSize: "1.5rem", fontWeight: 600 }}>Page not found</h1>
      <p>Some pages moved in a docs cleanup. Looking for one of these?</p>
      <ul style={{ display: "flex", flexDirection: "column", gap: "0.25rem" }}>
        <li>
          <Link href="/docs/features">Features</Link> (was Usage)
        </li>
        <li>
          <Link href="/docs/development">Development</Link> (was Build from Source)
        </li>
        <li>
          <Link href="/docs/settings">Settings</Link> (was Appearance)
        </li>
      </ul>
      <p>
        Or head to the <Link href="/docs">documentation home</Link>.
      </p>
    </main>
  );
}
