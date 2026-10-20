import { describe, expect, test } from "bun:test";
import tokens from "../tokens.json";
import { contrastRatio } from "../contrast";

describe("text token contrast", () => {
  test("uses the WCAG luminance formula", () => {
    expect(contrastRatio("#000000", "#FFFFFF")).toBe(21);
    expect(contrastRatio("#505057", "#505057")).toBe(1);
    expect(() => contrastRatio("transparent", "#FFFFFF")).toThrow();
  });

  for (const mode of ["light", "dark"] as const) {
    for (const [role, foreground] of Object.entries(tokens.color.text[mode])) {
      for (const surface of ["base", "surface", "elev"] as const) {
        test(`${mode} ${role} on ${surface} meets AAA text contrast`, () => {
          expect(contrastRatio(foreground, tokens.color.surface[mode][surface])).toBeGreaterThanOrEqual(7);
        });
      }
    }
  }
});
