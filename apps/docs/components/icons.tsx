import type { SVGProps } from "react";

/**
 * Brand glyphs that lucide-react 1.x dropped (it no longer ships brand
 * marks). Paths are the official Simple Icons glyphs (24×24, filled).
 *
 * They are drop-in replacements for the lucide components they replace:
 * size them with the same `w-* h-*` classes, colour comes from
 * `currentColor`, and they are decorative (`aria-hidden`) unless an
 * `aria-label` is passed.
 *
 * The viewBox is padded by 2 units on each side so the filled mark sits in
 * the same optical box as lucide's stroked icons (which draw inside a 2px
 * inset), keeping row heights and visual weight unchanged.
 */
type BrandIconProps = Omit<SVGProps<SVGSVGElement>, "children">;

function BrandIcon({
  path,
  title,
  ...props
}: BrandIconProps & { path: string; title: string }) {
  const labelled = props["aria-label"] !== undefined;
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="-2 -2 28 28"
      width={24}
      height={24}
      fill="currentColor"
      focusable="false"
      aria-hidden={labelled ? undefined : true}
      role={labelled ? "img" : undefined}
      data-brand-icon={title.toLowerCase()}
      {...props}
    >
      <path d={path} />
    </svg>
  );
}

const GITHUB_PATH =
  "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12";

const TWITCH_PATH =
  "M11.571 4.714h1.715v5.143H11.57zm4.715 0H18v5.143h-1.714zM6 0L1.714 4.286v15.428h5.143V24l4.286-4.286h3.428L22.286 12V0zm14.571 11.143l-3.428 3.428h-3.429l-3 3v-3H6.857V1.714h13.714Z";

/** GitHub mark (replaces lucide-react's removed `Github`). */
export function GithubIcon(props: BrandIconProps) {
  return <BrandIcon path={GITHUB_PATH} title="GitHub" {...props} />;
}

/** Twitch glitch mark (replaces lucide-react's removed `Twitch`). */
export function TwitchIcon(props: BrandIconProps) {
  return <BrandIcon path={TWITCH_PATH} title="Twitch" {...props} />;
}
