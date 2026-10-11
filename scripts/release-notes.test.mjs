//
//  release-notes.test.mjs
//  WolfWave
//
//  Pins release-notes.mjs against the constrained CHANGELOG subset: a flat
//  section renders, and indented / wrapped / `*` lines fail the run instead of
//  degrading into stray paragraphs in the Sparkle dialog.
//
//  Run: node --test scripts/release-notes.test.mjs
//

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("./release-notes.mjs", import.meta.url));

function run(changelog, version = "9.9.9") {
  const dir = mkdtempSync(join(tmpdir(), "release-notes-"));
  try {
    const changelogPath = join(dir, "CHANGELOG.md");
    const outPath = join(dir, "out.html");
    writeFileSync(changelogPath, changelog, "utf8");
    const result = spawnSync("node", [script, version, outPath], {
      env: { ...process.env, CHANGELOG_PATH: changelogPath },
      encoding: "utf8",
    });
    let html = null;
    try {
      html = readFileSync(outPath, "utf8");
    } catch {
      // not written on failure
    }
    return { status: result.status, stderr: result.stderr, html };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const flat = `# Changelog

## [9.9.9] - Unreleased

### Added

- A **bold** feature with \`code\`
- Another one

### Developer

> Contributor only.

- Internal detail

## [9.9.8] - 2026-01-01

### Fixed

- Old
`;

test("flat section renders bullets and drops the Developer block", () => {
  const { status, html } = run(flat);
  assert.equal(status, 0);
  assert.match(html, /<h2>Added<\/h2>/);
  assert.match(html, /<li>A <strong>bold<\/strong> feature with <code>code<\/code><\/li>/);
  assert.doesNotMatch(html, /Internal detail/);
  assert.doesNotMatch(html, /Old/);
});

test("indented sub-bullet exits non-zero", () => {
  const { status, stderr } = run(flat.replace("- Another one", "- Another one\n  - nested"));
  assert.notEqual(status, 0);
  assert.match(stderr, /unsupported CHANGELOG line/);
});

test("wrapped continuation line exits non-zero", () => {
  const { status } = run(flat.replace("- Another one", "- Another one\n  that wraps"));
  assert.notEqual(status, 0);
});

test("asterisk bullet exits non-zero", () => {
  const { status } = run(flat.replace("- Another one", "* Another one"));
  assert.notEqual(status, 0);
});

test("indented lines inside the stripped Developer block do not fail", () => {
  const { status } = run(flat.replace("- Internal detail", "- Internal detail\n  - nested"));
  assert.equal(status, 0);
});

test("the real CHANGELOG's newest section renders", () => {
  const changelog = readFileSync(new URL("../CHANGELOG.md", import.meta.url), "utf8");
  const version = changelog.match(/^## \[(\d+\.\d+\.\d+)\]/m)[1];
  const { status } = run(changelog, version);
  assert.equal(status, 0);
});
