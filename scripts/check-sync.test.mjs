import assert from "node:assert/strict";
import test from "node:test";

import {
  checkDocsText,
  checkLintRuleParity,
  checkRequiredHeadings,
  findDuplicateTokenLists,
} from "./check-sync.mjs";

const expected = {
  themes: ["Default", "Dark"],
  layouts: ["Horizontal", "Compact"],
  layoutSizes: {
    Horizontal: { width: 500, height: 100 },
    Compact: { width: 350, height: 56 },
  },
  viewportPadding: 32,
};

test("findDuplicateTokenLists catches token copies but permits generated references", () => {
  const copied = 'static let themes = ["Default", "Dark"]';
  assert.equal(findDuplicateTokenLists(copied, { themes: expected.themes }).length, 1);
  assert.deepEqual(findDuplicateTokenLists("static let themes = DSWidgetThemes.order", { themes: expected.themes }), []);
});

test("checkRequiredHeadings enforces the catalog template order", () => {
  const valid = ["Purpose", "API", "Tokens used", "Anatomy", "Accessibility", "Do / Don't", "Example"]
    .map((heading) => `## ${heading}`)
    .join("\n");
  assert.deepEqual(checkRequiredHeadings(valid), []);
  assert.deepEqual(checkRequiredHeadings(valid.replace("## Anatomy\n", "")), ["Anatomy"]);
});

test("checkDocsText derives counts, dimensions, and padding from source values", () => {
  const valid = `Two themes (\`Default\`, \`Dark\`) and two layouts (\`Horizontal\`, \`Compact\`).
| Layout | Card | Canvas |
|---|---:|---:|
| Horizontal | 500 × 100 | 532 × 132 |
| Compact | 350 × 56 | 382 × 88 |
The widget adds 16 px of padding on every side, so use a canvas 32 px larger than the generated card.`;
  assert.deepEqual(checkDocsText(valid, expected), []);
  assert.ok(checkDocsText(valid.replace("532 × 132", "533 × 132"), expected).some((failure) => failure.message.includes("dimensions")));
  assert.ok(checkDocsText(valid.replace("Two themes", "Three themes"), expected).some((failure) => failure.message.includes("theme count")));
});

test("checkLintRuleParity requires exact comment-to-RULES parity", () => {
  const source = `/**\n * Rules:\n * - \`raw-spacing\`: claim\n * - \`ghost-rule\`: claim\n */\nconst RULES = [{ name: "raw-spacing" }, { name: "raw-padding" }];`;
  assert.deepEqual(checkLintRuleParity(source), {
    unimplementedClaims: ["ghost-rule"],
    undocumentedRules: ["raw-padding"],
  });
});
