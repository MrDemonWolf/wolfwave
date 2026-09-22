#!/usr/bin/env node
//
// Blocks known source/documentation drift that cannot be caught by a compiler:
// token-derived Swift lists, component catalog coverage/template shape, widget
// values repeated in contributor docs, and design-system lint rule claims.

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const COMPONENT_ROOTS = [
  "apps/native/WolfWave/Views/Shared",
  "apps/native/WolfWave/Views/Onboarding/Components",
  "apps/native/WolfWave/Views/HistoryStats",
];
const CATALOG_DIR = "design-system/components";
const REQUIRED_HEADINGS = [
  "Purpose",
  "API",
  "Tokens used",
  "Anatomy",
  "Accessibility",
  "Do / Don't",
  "Example",
];
const DOC_FILES = [
  "README.md",
  "CLAUDE.md",
  "apps/docs/content/docs/features.mdx",
  "apps/docs/content/docs/widget.mdx",
];

function walk(dir, suffix, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) walk(full, suffix, out);
    else if (entry.name.endsWith(suffix)) out.push(full);
  }
  return out;
}

function lineAt(text, index) {
  return text.slice(0, index).split("\n").length;
}

function sameMembers(actual, expected) {
  return actual.length === expected.length && expected.every((value) => actual.includes(value));
}

function skipSwiftBlockComment(source, start) {
  let cursor = start + 2;
  let depth = 1;
  while (cursor < source.length && depth > 0) {
    if (source.startsWith("/*", cursor)) {
      depth += 1;
      cursor += 2;
    } else if (source.startsWith("*/", cursor)) {
      depth -= 1;
      cursor += 2;
    } else {
      cursor += 1;
    }
  }
  return cursor;
}

function skipSwiftTrivia(source, start) {
  let cursor = start;
  while (cursor < source.length) {
    if (/\s/.test(source[cursor])) {
      cursor += 1;
    } else if (source.startsWith("//", cursor)) {
      const newline = source.indexOf("\n", cursor + 2);
      cursor = newline === -1 ? source.length : newline + 1;
    } else if (source.startsWith("/*", cursor)) {
      cursor = skipSwiftBlockComment(source, cursor);
    } else {
      break;
    }
  }
  return cursor;
}

function readSwiftString(source, start) {
  let cursor = start + 1;
  while (cursor < source.length) {
    if (source[cursor] === "\\") cursor += 2;
    else if (source[cursor] === '"') return { value: source.slice(start + 1, cursor), end: cursor + 1 };
    else cursor += 1;
  }
  return null;
}

function parseSwiftStringArray(source, start) {
  const values = [];
  let cursor = skipSwiftTrivia(source, start + 1);
  while (source[cursor] === '"') {
    const string = readSwiftString(source, cursor);
    if (!string) return null;
    values.push(string.value);
    cursor = skipSwiftTrivia(source, string.end);
    if (source[cursor] !== ",") break;
    cursor = skipSwiftTrivia(source, cursor + 1);
  }
  return values.length > 0 && source[cursor] === "]" ? { values, end: cursor + 1 } : null;
}

export function findDuplicateTokenLists(source, groups) {
  const failures = [];
  let cursor = 0;
  while (cursor < source.length) {
    if (source.startsWith("//", cursor)) {
      const newline = source.indexOf("\n", cursor + 2);
      cursor = newline === -1 ? source.length : newline + 1;
    } else if (source.startsWith("/*", cursor)) {
      cursor = skipSwiftBlockComment(source, cursor);
    } else if (source[cursor] === '"') {
      cursor = readSwiftString(source, cursor)?.end ?? source.length;
    } else if (source[cursor] === "[") {
      const array = parseSwiftStringArray(source, cursor);
      if (!array) {
        cursor += 1;
        continue;
      }
      for (const [label, expected] of Object.entries(groups)) {
        if (sameMembers(array.values, expected)) {
          failures.push({
            line: lineAt(source, cursor),
            message: `duplicates token-derived widget ${label}; reference the generated token list instead`,
          });
        }
      }
      cursor = array.end;
    } else {
      cursor += 1;
    }
  }
  return failures;
}

export function checkRequiredHeadings(text) {
  const headings = [...text.matchAll(/^## (.+)$/gm)].map((match) => match[1]);
  let cursor = -1;
  const missing = [];
  for (const required of REQUIRED_HEADINGS) {
    const next = headings.indexOf(required, cursor + 1);
    if (next === -1) missing.push(required);
    else cursor = next;
  }
  return missing;
}

export function checkLintRuleParity(source) {
  const implemented = [...source.matchAll(/\bname:\s*"([a-z0-9-]+)"/g)].map((match) => match[1]);
  const rulesComment = source.match(/\* Rules:\s*([\s\S]*?)\*\//)?.[1] ?? "";
  const claimed = [...rulesComment.matchAll(/`([a-z0-9-]+)`/g)].map((match) => match[1]);
  return {
    unimplementedClaims: claimed.filter((name) => !implemented.includes(name)),
    undocumentedRules: implemented.filter((name) => !claimed.includes(name)),
  };
}

const NUMBER_WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];

function claimedNumber(raw) {
  const number = Number(raw);
  return Number.isNaN(number) ? NUMBER_WORDS.indexOf(raw.toLowerCase()) : number;
}

function markdownTableBlocks(text) {
  const lines = text.split("\n");
  const tables = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (!/^\|\s*Layout\s*\|/.test(lines[index])) continue;
    const rows = [];
    for (let row = index + 2; row < lines.length && lines[row].startsWith("|"); row += 1) {
      rows.push({ line: row + 1, cells: lines[row].split("|").slice(1, -1).map((cell) => cell.trim()) });
    }
    tables.push(rows);
  }
  return tables;
}

export function checkDocsText(text, expected) {
  const failures = [];
  const countChecks = [
    ["theme", expected.themes.length, /\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+(?:selectable\s+)?themes?\b/gi],
    ["layout", expected.layouts.length, /\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+layouts?\b/gi],
  ];
  for (const [label, count, pattern] of countChecks) {
    for (const match of text.matchAll(pattern)) {
      if (claimedNumber(match[1]) !== count) {
        failures.push({ line: lineAt(text, match.index), message: `${label} count is ${match[1]}; tokens define ${count}` });
      }
    }
  }

  for (const match of text.matchAll(/\(([^()]*)\)/gs)) {
    const values = [...match[1].matchAll(/`([^`]+)`/g)].map((item) => item[1]);
    for (const [label, names] of [["theme", expected.themes], ["layout", expected.layouts]]) {
      if (values.some((value) => names.includes(value)) && !sameMembers(values, names)) {
        failures.push({ line: lineAt(text, match.index), message: `${label} list does not match tokens: ${names.join(", ")}` });
      }
    }
  }

  const proseThemes = text.match(/The selectable themes are ([^.]+)\./);
  if (proseThemes) {
    const values = proseThemes[1].split(/,|\band\b/).map((value) => value.replace(/`/g, "").trim()).filter(Boolean);
    if (!sameMembers(values, expected.themes)) {
      failures.push({ line: lineAt(text, proseThemes.index), message: `selectable theme list does not match tokens: ${expected.themes.join(", ")}` });
    }
  }

  for (const rows of markdownTableBlocks(text)) {
    const names = rows.map((row) => row.cells[0]);
    if (!sameMembers(names, expected.layouts)) {
      failures.push({ line: rows[0]?.line ?? 1, message: `widget layout table does not match tokens: ${expected.layouts.join(", ")}` });
      continue;
    }
    for (const row of rows) {
      const layout = expected.layoutSizes[row.cells[0]];
      const allowed = new Set([
        `${layout.width}x${layout.height}`,
        `${layout.width + expected.viewportPadding}x${layout.height + expected.viewportPadding}`,
      ]);
      for (const dimensions of row.cells.slice(1).join(" ").matchAll(/(\d+)\s*[x×]\s*(\d+)/g)) {
        const value = `${dimensions[1]}x${dimensions[2]}`;
        if (!allowed.has(value)) {
          failures.push({ line: row.line, message: `${row.cells[0]} dimensions ${value} do not match tokens or the padded OBS canvas` });
        }
      }
    }
  }

  for (const match of text.matchAll(/adds\s+(\d+)\s+px[^.]*every side/gi)) {
    if (Number(match[1]) * 2 !== expected.viewportPadding) {
      failures.push({ line: lineAt(text, match.index), message: `per-side padding ${match[1]} does not match viewportPadding ${expected.viewportPadding}` });
    }
  }
  for (const match of text.matchAll(/(\d+)\s+px\s+larger than the generated card/gi)) {
    if (Number(match[1]) !== expected.viewportPadding) {
      failures.push({ line: lineAt(text, match.index), message: `total canvas padding ${match[1]} does not match viewportPadding ${expected.viewportPadding}` });
    }
  }
  return failures;
}

function projectExpected(root) {
  const tokens = JSON.parse(readFileSync(resolve(root, "design-system/tokens.json"), "utf8"));
  const themes = Object.entries(tokens.widget.themes).filter(([, value]) => !value.hidden).map(([name]) => name);
  const layouts = Object.keys(tokens.widget.layouts);
  const layoutSizes = Object.fromEntries(
    Object.entries(tokens.widget.layouts).map(([name, value]) => [name, { width: value.maxWidth, height: value.height }]),
  );
  const appConstants = readFileSync(resolve(root, "apps/native/WolfWave/Core/AppConstants.swift"), "utf8");
  const viewportPadding = Number(appConstants.match(/static let viewportPadding = (\d+)/)?.[1]);
  if (!Number.isFinite(viewportPadding)) throw new Error("Could not read AppConstants.Widget.viewportPadding");
  return { themes, layouts, layoutSizes, viewportPadding };
}

function catalogFailures(root) {
  const failures = [];
  const sources = COMPONENT_ROOTS.flatMap((dir) => walk(resolve(root, dir), ".swift"))
    .map((file) => relative(root, file));
  const catalogPath = resolve(root, CATALOG_DIR);
  const docs = readdirSync(catalogPath)
    .filter((name) => name.endsWith(".md") && name !== "README.md")
    .sort();
  const documented = new Map();

  for (const name of docs) {
    const path = join(catalogPath, name);
    const text = readFileSync(path, "utf8");
    const declaration = text.match(/^\*\*File:\*\*\s+(?:\[[^\]]+\]\(([^)]+)\)|`([^`]+)`)/m);
    if (!declaration) {
      failures.push({ file: relative(root, path), line: 3, message: "missing **File:** source declaration" });
    } else {
      const target = declaration[1]
        ? resolve(dirname(path), declaration[1])
        : resolve(root, declaration[2]);
      const source = relative(root, target);
      if (!sources.includes(source)) {
        failures.push({ file: relative(root, path), line: 3, message: `catalog source is missing or outside the covered component roots: ${source}` });
      } else {
        documented.set(source, [...(documented.get(source) ?? []), name]);
      }
    }
    const missing = checkRequiredHeadings(text);
    if (missing.length > 0) {
      failures.push({ file: relative(root, path), line: 1, message: `missing or out-of-order template headings: ${missing.join(", ")}` });
    }
  }

  for (const source of sources) {
    if (!documented.has(source)) failures.push({ file: source, line: 1, message: "missing component catalog entry" });
  }

  const index = readFileSync(join(catalogPath, "README.md"), "utf8");
  const indexed = new Set([...index.matchAll(/\]\(([a-z0-9-]+\.md)\)/g)].map((match) => match[1]));
  for (const name of docs) {
    if (!indexed.has(name)) failures.push({ file: `${CATALOG_DIR}/${name}`, line: 1, message: "catalog entry is missing from the README index" });
  }
  for (const name of indexed) {
    if (!docs.includes(name)) failures.push({ file: `${CATALOG_DIR}/README.md`, line: 1, message: `index links missing catalog entry ${name}` });
  }
  return failures;
}

export function runChecks(root = ROOT) {
  const failures = [];
  const expected = projectExpected(root);

  for (const file of walk(resolve(root, "apps/native/WolfWave"), ".swift")) {
    if (file.endsWith(".generated.swift")) continue;
    const text = readFileSync(file, "utf8");
    for (const failure of findDuplicateTokenLists(text, { themes: expected.themes, layouts: expected.layouts })) {
      failures.push({ file: relative(root, file), ...failure });
    }
  }

  failures.push(...catalogFailures(root));

  for (const file of DOC_FILES) {
    const text = readFileSync(resolve(root, file), "utf8");
    for (const failure of checkDocsText(text, expected)) failures.push({ file, ...failure });
  }

  const lintFile = "design-system/scripts/lint.ts";
  const parity = checkLintRuleParity(readFileSync(resolve(root, lintFile), "utf8"));
  for (const name of parity.unimplementedClaims) failures.push({ file: lintFile, line: 1, message: `comment claims unimplemented rule ${name}` });
  for (const name of parity.undocumentedRules) failures.push({ file: lintFile, line: 1, message: `RULES entry ${name} is missing from the Rules comment` });
  return failures;
}

if (resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  const failures = runChecks();
  if (failures.length === 0) {
    console.log("✅ Source-derived lists, component catalog, docs values, and lint claims are in sync.");
    process.exit(0);
  }
  for (const failure of failures) {
    const message = `${failure.file}:${failure.line}: ${failure.message}`;
    console.log(process.env.GITHUB_ACTIONS ? `::error file=${failure.file},line=${failure.line}::${failure.message}` : message);
  }
  console.log(`\n❌ ${failures.length} sync problem(s). Run make lint-sync after updating source or docs.`);
  process.exit(1);
}
