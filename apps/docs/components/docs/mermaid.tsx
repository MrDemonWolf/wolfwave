"use client";
import { useEffect, useId, useRef, useState } from "react";

/** The smallest scale a diagram may shrink to before its frame scrolls instead. */
const MIN_SCALE = 0.72;

/**
 * Mermaid sizes its SVG to `width="100%"`, capped at its natural width, so a
 * wide diagram in a narrow column shrinks until its labels are unreadable.
 * Add a floor: it scales to fit down to `MIN_SCALE`, then the frame scrolls.
 */
function withMinimumScale(svg: string): string {
  const element = new DOMParser().parseFromString(svg, "image/svg+xml").documentElement;
  const natural = Number.parseFloat(element.style.maxWidth);
  if (!Number.isFinite(natural) || natural <= 0) return svg;
  element.style.minWidth = `${Math.ceil(natural * MIN_SCALE)}px`;
  return new XMLSerializer().serializeToString(element);
}

/** Reads a design token from the live page, so diagrams follow light and dark mode. */
function token(name: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

/**
 * Renders a ```mermaid fence (converted by `rehypeMermaid` in
 * `lib/rehype-docs.ts`) as an SVG diagram in the browser. Mermaid loads only on
 * pages that have a diagram, and redraws when the theme changes. Until it has
 * drawn, the box keeps its space and the source text stays readable to screen
 * readers.
 */
export function Mermaid({ chart }: { chart: string }) {
  const id = `mermaid-${useId().replace(/[^a-zA-Z0-9-]/g, "")}`;
  // Mermaid deletes any element with the render id before drawing, so each
  // render gets a fresh one; reusing it would blank the diagram on screen.
  const renders = useRef(0);
  const [svg, setSvg] = useState<string>();
  const [dark, setDark] = useState<boolean>();

  useEffect(() => {
    const html = document.documentElement;
    const update = () => setDark(html.classList.contains("dark"));
    update();
    const observer = new MutationObserver(update);
    observer.observe(html, { attributes: true, attributeFilter: ["class"] });
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (dark === undefined) return;
    let cancelled = false;
    (async () => {
      const { default: mermaid } = await import("mermaid");
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme: "base",
        fontFamily: token("--font-roboto") || "Roboto, system-ui, sans-serif",
        themeVariables: {
          darkMode: dark,
          background: token("--ds-color-surface-base"),
          primaryColor: token("--ds-color-surface-base"),
          primaryTextColor: token("--ds-color-text-primary"),
          primaryBorderColor: token("--ds-color-brand-500"),
          secondaryColor: token("--ds-color-surface-surface"),
          tertiaryColor: token("--ds-color-surface-surface"),
          lineColor: token("--ds-color-text-secondary"),
          textColor: token("--ds-color-text-primary"),
          edgeLabelBackground: token("--ds-color-surface-surface"),
          fontSize: "14px",
        },
        flowchart: { curve: "basis", padding: 10, nodeSpacing: 22, rankSpacing: 40 },
      });
      renders.current += 1;
      const { svg: rendered } = await mermaid.render(`${id}-${renders.current}`, chart);
      if (!cancelled) setSvg(withMinimumScale(rendered));
    })().catch(() => {
      if (!cancelled) setSvg(undefined);
    });
    return () => {
      cancelled = true;
    };
  }, [chart, dark, id]);

  return (
    <figure className="ww-mermaid" data-ready={svg ? "" : undefined}>
      {svg ? <div className="ww-mermaid-svg" dangerouslySetInnerHTML={{ __html: svg }} /> : null}
      <pre className={svg ? "sr-only" : "ww-mermaid-source"}>
        <code>{chart}</code>
      </pre>
    </figure>
  );
}
