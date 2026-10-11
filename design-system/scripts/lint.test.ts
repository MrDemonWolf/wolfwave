import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { RULES } from "./lint";

function rule(name: string) {
  const found = RULES.find((r) => r.name === name);
  if (!found) throw new Error(`${name} rule is missing`);
  return found;
}

function flags(name: string, line: string): boolean {
  return rule(name).pattern.test(line);
}

const tokens = JSON.parse(
  readFileSync(resolve(import.meta.dir, "..", "tokens.json"), "utf8")
);

// Spacing values straight from tokens.json, so the rule's hard-coded list
// cannot drift from the scale it is policing.
const spacingValues: number[] = Object.values(tokens.space as Record<string, number>).filter(
  (v) => v > 0
);
// Radius scale, minus the pill (9999 is a "fully round" sentinel, not a size).
const radiusValues: number[] = Object.values(tokens.radius as Record<string, number>).filter(
  (v) => v < 1000
);

describe("rule table", () => {
  test("Onboarding carve-out: only motion and status color apply there", () => {
    expect(rule("raw-font-size").appliesToOnboarding).toBe(false);
    expect(rule("raw-spacing").appliesToOnboarding).toBe(false);
    expect(rule("raw-padding").appliesToOnboarding).toBe(false);
    expect(rule("raw-radius").appliesToOnboarding).toBe(false);
    expect(rule("raw-animation-duration").appliesToOnboarding).toBe(true);
    expect(rule("raw-status-color").appliesToOnboarding).toBe(true);
  });
});

describe("raw-font-size", () => {
  test.each([
    ["Text(a).font(.system(size: 13))"],
    ["Text(a).font(.system(size: 13, weight: .semibold))"],
    ["Text(a).font(.system(size:13))"],
    ["let f = Font.system(size: 22, design: .rounded)"],
    ["static let f = .system( size: 11)"],
  ])("flags %j", (line) => {
    expect(flags("raw-font-size", line)).toBe(true);
  });

  test.each([
    ["Text(a).font(.system(size: DSFont.Size.base))"],
    ["Text(a).font(.system(size: DSFont.Size.sm, weight: .medium))"],
    ["Text(a).font(.body)"],
    ["Text(a).paneTitle()"],
  ])("ignores %j", (line) => {
    expect(flags("raw-font-size", line)).toBe(false);
  });

  test("NOT caught: call split across lines", () => {
    expect(flags("raw-font-size", ".font(.system(")).toBe(false);
    expect(flags("raw-font-size", "    size: 13,")).toBe(false);
  });
});

describe("raw-spacing", () => {
  test.each([
    ["VStack(spacing: 12) {"],
    ["HStack(alignment: .top, spacing: 8) {"],
    ["VStack(spacing: 4)"],
    ["LazyVGrid(columns: c, spacing: 16, content: { })"],
    ["VStack(spacing: 12.0) {"],
    ["HStack(spacing: 8.00, content: { })"],
  ])("flags %j", (line) => {
    expect(flags("raw-spacing", line)).toBe(true);
  });

  test.each([
    ["VStack(spacing: 0) {"],
    ["VStack(spacing: DSSpace.s4) {"],
    ["HStack(spacing: AppConstants.SettingsUI.sectionSpacing)"],
    ["VStack(spacing: 12.5) {"],
    ["VStack(spacing: 12.05) {"],
  ])("ignores %j", (line) => {
    expect(flags("raw-spacing", line)).toBe(false);
  });

  test("NOT caught: off-scale literal with no token", () => {
    expect(flags("raw-spacing", "VStack(spacing: 1.5) {")).toBe(false);
    expect(flags("raw-spacing", "VStack(spacing: 3) {")).toBe(false);
  });

  test("flags every positive spacing token value", () => {
    expect(spacingValues.length).toBeGreaterThan(5);
    for (const value of spacingValues) {
      expect(flags("raw-spacing", `VStack(spacing: ${value}) {`)).toBe(true);
    }
  });
});

describe("raw-padding", () => {
  test.each([
    [".padding(16)"],
    [".padding( 8 )"],
    [".padding(.horizontal, 12)"],
    [".padding(.top, 8)"],
    [".padding(.vertical,4)"],
    [".padding([.horizontal, .top], 12)"],
    [".padding([.leading, .trailing], 20)"],
    [".padding(16.0)"],
    [".padding(.horizontal, 16.0)"],
  ])("flags %j", (line) => {
    expect(flags("raw-padding", line)).toBe(true);
  });

  test.each([
    [".padding()"],
    [".padding(DSSpace.s4)"],
    [".padding(.horizontal, DSSpace.s4)"],
    [".padding(.vertical, DSSpace.s1)"],
    [".padding([.horizontal, .top], DSSpace.s4)"],
    [".padding(.top, 0)"],
    [".padding(.top, 12.5)"],
    [".padding(12.5)"],
  ])("ignores %j", (line) => {
    expect(flags("raw-padding", line)).toBe(false);
  });

  test("NOT caught: call split across lines", () => {
    expect(flags("raw-padding", ".padding(.horizontal,")).toBe(false);
  });

  test("flags every positive spacing token value in both forms", () => {
    for (const value of spacingValues) {
      expect(flags("raw-padding", `.padding(${value})`)).toBe(true);
      expect(flags("raw-padding", `.padding(.horizontal, ${value})`)).toBe(true);
    }
  });
});

describe("raw-radius", () => {
  test.each([
    ["RoundedRectangle(cornerRadius: 12)"],
    ["RoundedRectangle(cornerRadius: 8, style: .continuous)"],
    [".clipShape(.rect(cornerRadius: 10))"],
    ["BarMark(x: a, y: b).cornerRadius(4)"],
    [".cornerRadius( 6 )"],
    ["UnevenRoundedRectangle(cornerRadius:16)"],
    ["RoundedRectangle(cornerRadius: 8.0)"],
    [".cornerRadius(4.0)"],
  ])("flags %j", (line) => {
    expect(flags("raw-radius", line)).toBe(true);
  });

  test.each([
    ["RoundedRectangle(cornerRadius: DSRadius.lg2)"],
    ["RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)"],
    [".cornerRadius(DSRadius.xs)"],
    ["RoundedRectangle(cornerRadius: radius)"],
    ["RoundedRectangle(cornerRadius: 12.5)"],
    [".cornerRadius(8.5)"],
    [".shadow(color: .black, radius: 8)"],
  ])("ignores %j", (line) => {
    expect(flags("raw-radius", line)).toBe(false);
  });

  test("NOT caught: off-scale literal with no token", () => {
    expect(flags("raw-radius", ".cornerRadius(2)")).toBe(false);
    expect(flags("raw-radius", "RoundedRectangle(cornerRadius: 3)")).toBe(false);
  });

  test("flags every sized radius token value in both forms", () => {
    expect(radiusValues.length).toBeGreaterThan(5);
    for (const value of radiusValues) {
      expect(flags("raw-radius", `RoundedRectangle(cornerRadius: ${value})`)).toBe(true);
      expect(flags("raw-radius", `.cornerRadius(${value})`)).toBe(true);
    }
  });
});

describe("raw-animation-duration", () => {
  test.each([
    [".easeInOut(duration: 0.2)"],
    [".easeOut(duration: 0.4)"],
    [".linear(duration: 1)"],
    [".spring(response: 0.35, dampingFraction: 0.8)"],
    ["withAnimation(.easeIn(duration: 0.15)) { x = true }"],
  ])("flags %j", (line) => {
    expect(flags("raw-animation-duration", line)).toBe(true);
  });

  test.each([
    [".easeInOut(duration: DSMotion.Duration.fast)"],
    [".spring(response: DSMotion.Duration.base, dampingFraction: 0.8)"],
    [".easeInOut(duration: someVar)"],
    ["withAnimation(.default) { x = true }"],
  ])("ignores %j", (line) => {
    expect(flags("raw-animation-duration", line)).toBe(false);
  });
});

describe("raw-status-color", () => {
  const statusColor = rule("raw-status-color");

  test("the rule exists and covers Onboarding", () => {
    // Status semantics are universal; Onboarding's separate visual language
    // does not extend to what "off" or "error" is tinted.
    expect(statusColor.appliesToOnboarding).toBe(true);
  });

  const f = (line: string) => flags("raw-status-color", line);

  // Every form the migration actually found in the codebase.
  test.each([
    ['StatusChip(text: "On", color: .green, systemImage: g)', "chip, green"],
    ['StatusChip(text: "Off", color: .secondary, systemImage: g)', "chip, translucent secondary"],
    ['StatusChip(text: "Paused", color: .orange)', "chip, no glyph"],
    ["case .stopped:   return .gray", "bare return is NOT caught"],
    ["statusColor: trackingEnabled ? .green : .gray", "ternary in a labeled arg"],
    ["color: Color.gray", "explicit Color. prefix"],
    ["statusColor: .red,", "trailing comma"],
    ["color: .yellow", "yellow"],
    ["color: .blue", "blue"],
  ])("flags %j (%s)", (line, label) => {
    // The bare-return case is the documented blind spot: it carries no argument
    // label, so a line-based rule cannot see it. Asserted here so the limit is
    // recorded rather than discovered later.
    const expected = !label.includes("NOT caught");
    expect(f(line)).toBe(expected);
  });

  // Deliberate raw colors. A false positive here would force allowlist entries
  // for correct code, which is how a lint rule earns its way to being disabled.
  test.each([
    [".shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)", "shadow black"],
    [".shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)", "shadow, Color. prefix"],
    ['StatusChip(text: "Twitch", color: .purple)', "category tag, not a status"],
    ["if updateAvailable { return .accentColor }", "system accent"],
    ["case .stopped: return Color.white.opacity(0.35)", "fixed brand surface"],
    [".foregroundStyle(.secondary)", "body text"],
    ['Text(step).foregroundStyle(.red)', "not a color: label"],
    ["LinearGradient(colors: [.green, .blue], startPoint: .top, endPoint: .bottom)", "colors: is a different label"],
    [".shadow(color: glowColor.opacity(0.40), radius: 11)", "glowColor is not the color: label"],
    ["color: DSColor.neutral", "the fixed form"],
    ["statusColor: DSColor.success,", "the fixed form, labeled"],
  ])("ignores %j (%s)", (line) => {
    expect(f(line)).toBe(false);
  });
});
