import { expect, test } from "bun:test";
import tokens from "../../../design-system/tokens.json";

function color(value: string): number[] {
  if (value === "transparent") return [0, 0, 0, 0];
  if (value.startsWith("#")) return [1, 3, 5].map((i) => parseInt(value.slice(i, i + 2), 16)).concat(1);
  return value.slice(value.indexOf("(") + 1, -1).split(",").map(Number);
}

function over(fg: number[], bg: number[]): number[] {
  return bg.map((v, i) => fg[i] * fg[3] + v * (1 - fg[3]));
}

function luminance(rgb: number[]): number {
  return rgb.map((v) => v / 255).map((v) => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)
    .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
}

test("overlay preset text meets AA over black and white scenes", () => {
  for (const [name, theme] of Object.entries(tokens.widget.themes)) {
    for (const scene of [[0, 0, 0], [255, 255, 255]]) {
      const surface = over(color(theme.containerBg), scene);
      // Blurred artwork can be completely white, irrespective of the scene.
      const art = theme.showArtworkBlur ? [255, 255, 255] : surface;
      const bg = over(color(theme.overlayBg), art);
      for (const field of ["textPrimary", "textSecondary", "textMuted"] as const) {
        const fg = over(color(theme[field]), bg);
        // The decorative noise sits above text at 4% opacity.
        for (const noise of [[0, 0, 0, 0.04], [255, 255, 255, 0.04]]) {
          const a = luminance(over(noise, fg)), b = luminance(over(noise, bg));
          const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
          expect(ratio, `${name}.${field} on ${scene[0] === 0 ? "black" : "white"}`).toBeGreaterThanOrEqual(4.5);
        }
      }
    }
  }
});
