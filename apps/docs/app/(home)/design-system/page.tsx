import type { Metadata } from "next";
import Link from "next/link";
import { ArrowRight, AudioLines, Check, Moon, Sun } from "lucide-react";
import tokens from "../../../../../design-system/tokens.json";
import { contrastRatio } from "../../../../../design-system/contrast";
import { absoluteUrl, pageUrl, repoUrl } from "@/lib/site";
import { jsonLdScript } from "@/lib/seo";
import styles from "./system.module.css";

const title = "WolfWave Design System: Color, Typography & Motion";
const description = "Explore WolfWave’s shared design system: Montserrat and Roboto typography, accessible light and dark colors, reusable components, and considered motion.";
const image = { url: absoluteUrl("/og/docs/design-system/image.png"), width: 1200, height: 630, alt: "WolfWave Design System: tokens, components, brand, and one shared source." };

export const metadata: Metadata = {
  title: { absolute: title }, description,
  keywords: ["WolfWave design system", "accessible macOS app design", "WolfWave design tokens", "stream overlay design"],
  alternates: { canonical: pageUrl("/design-system") },
  openGraph: { type: "website", title, description, url: pageUrl("/design-system"), siteName: "WolfWave", images: [image] },
  twitter: { card: "summary_large_image", title, description, images: [image.url] },
};

export default function DesignSystemPage() {
  return (
    <main id="nd-page" tabIndex={-1} className={`ww-font ww-bg-base ${styles.page}`}>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: jsonLdScript({
        "@context": "https://schema.org", "@type": "WebPage", name: title, description,
        url: pageUrl("/design-system"), about: { "@type": "SoftwareApplication", name: "WolfWave", operatingSystem: "macOS 26+", applicationCategory: "MultimediaApplication" },
      }) }} />
      <header className={styles.hero}>
        <p className="ww-kicker"><AudioLines size={16} aria-hidden="true" /> The WolfWave system</p>
        <h1 className="ww-display">Every detail.<br /><span className="ww-text-brand">On the same wavelength.</span></h1>
        <p className={styles.intro}>A shared visual language for a small Mac app with a big presence. Clear type, quiet surfaces, and motion that keeps up with your music.</p>
        <nav aria-label="Design system sections" className={styles.links}>
          {["Typography", "Color", "Components", "Motion"].map((label) => <a key={label} href={`#${label.toLowerCase()}`} className="ww-btn ww-btn-secondary">{label}</a>)}
        </nav>
      </header>

      <section id="typography" className={styles.section} aria-labelledby="typography-title">
        <div className={styles.heading}><p className="ww-kicker">01 / Typography</p><h2 id="typography-title" className="ww-display">A familiar voice. Room to read.</h2><p>Drawn from the MrDemonWolf website: Montserrat for headings, Roboto for reading, and JetBrains Mono for code. Web body text starts at 16px with generous line spacing.</p></div>
        <div className={styles.typeGrid}>
          <div className={styles.specimen}><span className={styles.label}>Montserrat / Display</span><p className={styles.displaySample}>Made for<br />your next set.</p><p className="ww-text-2">Medium and semibold. Balanced lines, deliberate spacing.</p></div>
          <div className={styles.specimen}><span className={styles.label}>Roboto / Body</span><p className={styles.bodySample}>Your music belongs in the moment. Keep the current song in view, let chat join the queue, and carry on with your stream.</p><p className="ww-mono">JetBrains Mono / !song</p><div className={styles.scale}>{["webSmall", "webBody", "webSection", "webHero"].map((key) => <span key={key}><strong>{tokens.font.size[key as keyof typeof tokens.font.size]}px</strong>{key.replace("web", "")}</span>)}</div></div>
        </div>
        <p className={styles.note}>Headlines scale down to fit smaller screens. Native app controls retain their macOS type scale; web sizes are separate tokens.</p>
      </section>

      <section id="color" className={styles.section} aria-labelledby="color-title">
        <div className={styles.heading}><p className="ww-kicker">02 / Color & contrast</p><h2 id="color-title" className="ww-display">Bright personality. Clear information.</h2><p>System blue anchors the product. Primary, secondary, and muted text tokens meet 7:1 contrast on the three solid surfaces in each theme. Color always has a text label.</p></div>
        <div className={styles.colorGrid}>
          {(["light", "dark"] as const).map((mode) => <article key={mode} className={styles.palette} style={{ background: tokens.color.surface[mode].base, color: tokens.color.text[mode].primary, borderColor: tokens.color.surface[mode].hairline }}>
            <h3>{mode === "light" ? <Sun aria-hidden="true" size={20} /> : <Moon aria-hidden="true" size={20} />}{mode === "light" ? "Light" : "Dark"} appearance</h3>
            <p style={{ color: tokens.color.text[mode].secondary }}>A quieter background for whatever is playing.</p>
            {Object.entries(tokens.color.text[mode]).map(([role, foreground]) => <div key={role} className={styles.colorRow} style={{ color: foreground }}><span className={styles.swatch} style={{ background: foreground }} /><span>{role}<code>{foreground}</code></span><strong>{contrastRatio(foreground, tokens.color.surface[mode].base).toFixed(2)}:1<span>AAA text</span></strong></div>)}
          </article>)}
        </div>
        <p className={styles.note}>These are measured token pairs, not a blanket accessibility certification. Interactive text targets AA (4.5:1); large text and meaningful UI boundaries target 3:1. Transparent overlays must be checked against the actual scene.</p>
      </section>

      <section id="components" className={styles.section} aria-labelledby="components-title">
        <div className={styles.heading}><p className="ww-kicker">03 / Components</p><h2 id="components-title" className="ww-display">Small pieces. One clear rhythm.</h2><p>Flat cards, simple hierarchy, and actions you can reach with a keyboard. These examples use the same components and styles as the website.</p></div>
        <div className={styles.componentGrid}>
          <article className={styles.specimen}><span className={styles.label}>Actions / Primary & secondary</span><h3>Ready when you are.</h3><p className="ww-text-2">One next step, with help close by.</p><div className={styles.links}><Link href="/download" className="ww-btn ww-btn-primary">Get WolfWave <ArrowRight size={16} aria-hidden="true" /></Link><Link href="/docs" className="ww-btn ww-btn-secondary">Read the docs</Link></div></article>
          <article className={styles.specimen}><span className={styles.label}>Feedback / Text & icon</span><h3><Check size={20} aria-hidden="true" /> All in sync</h3><p className="ww-text-2">State is spelled out, with an icon to reinforce it. Focus rings show where you are when navigating by keyboard.</p><Link href="/#overlay" className="ww-btn ww-btn-secondary">Explore the overlay <ArrowRight size={16} aria-hidden="true" /></Link></article>
        </div>
      </section>

      <section id="motion" className={styles.section} aria-labelledby="motion-title">
        <div className={styles.heading}><p className="ww-kicker">04 / Motion</p><h2 id="motion-title" className="ww-display">Feel the change. Keep your focus.</h2><p>Short transitions explain what changed. Transform and opacity carry entrances; reduced motion keeps the same information without movement.</p></div>
        <div className={styles.motionGrid}>{Object.entries(tokens.motion.duration).map(([name, duration]) => <button type="button" key={name} className={`${styles.specimen} ${styles.motionSample}`} aria-label={`Preview ${name} motion, ${duration} milliseconds`}><span className={styles.label}>{name}</span><span className={styles.duration}>{duration}<span>ms</span></span><span className={styles.motionTrack}><span style={{ transitionDuration: `${duration}ms` }} /></span></button>)}</div>
        <p className={styles.note}>Hover or focus the motion samples to compare timing. Overlay progress pauses while hidden; preview colors come from the same tokens as the shipped widget.</p>
        <div className={styles.links}><Link href="/docs/design-system" className="ww-btn ww-btn-primary">Explore the full reference <ArrowRight aria-hidden="true" size={16} /></Link><a className="ww-btn ww-btn-secondary" href={`${repoUrl}/blob/main/design-system/tokens.json`}>View the source tokens</a></div>
      </section>
    </main>
  );
}
