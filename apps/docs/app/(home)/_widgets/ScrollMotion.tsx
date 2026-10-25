"use client";

import { useEffect } from "react";

/** Install visible entrances, canceling active motion when the preference changes. */
export function startScrollMotion() {
  const media = window.matchMedia("(prefers-reduced-motion: reduce)");
  const targets = [...document.querySelectorAll<HTMLElement>(
    "#nd-page [data-scroll-reveal]",
  )];
  const animations = new Map<Element, Animation>();
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      animations.get(entry.target)?.cancel();
      animations.delete(entry.target);
      if (!entry.isIntersecting) continue;
      if (media.matches || entry.target.matches(":focus-within")) continue;
      const animation = entry.target.animate(
        [{ transform: "translateY(6px)" }, { transform: "translateY(0)" }],
        { duration: 280, easing: "ease" },
      );
      animations.set(entry.target, animation);
      animation.onfinish = () => animations.delete(entry.target);
    }
  }, { threshold: 0, rootMargin: "0px" });

  const update = () => {
    observer.disconnect();
    for (const animation of animations.values()) animation.cancel();
    animations.clear();
    if (!media.matches) targets.forEach((target) => observer.observe(target));
  };
  update();
  media.addEventListener("change", update);
  return () => {
    observer.disconnect();
    media.removeEventListener("change", update);
    for (const animation of animations.values()) animation.cancel();
  };
}

/** Replay entrances when content returns to the readable viewport. */
export function ScrollMotion() {
  useEffect(startScrollMotion, []);
  return null;
}
