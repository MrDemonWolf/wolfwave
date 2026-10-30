#!/usr/bin/env node
//
// Blocks known source/documentation drift that cannot be caught by a compiler:
// token-derived Swift lists, component catalog coverage/template shape, widget
// values repeated in contributor docs, design-system lint rule claims, and the
// bug-report form fields the app prefills.

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** Repo root, resolved from this file's location so the script works from any cwd. */
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
/** Swift directories whose views must each have a catalog entry in `CATALOG_DIR`. */
const COMPONENT_ROOTS = [
  "apps/native/WolfWave/Views/Shared",
  "apps/native/WolfWave/Views/Onboarding/Components",
  "apps/native/WolfWave/Views/HistoryStats",
];
const CATALOG_DIR = "design-system/components";
/** Section headings every catalog entry must contain, in this order (see status-chip.md). */
const REQUIRED_HEADINGS = [
  "Purpose",
  "API",
  "Tokens used",
  "Anatomy",
  "Accessibility",
  "Do / Don't",
  "Example",
];
/** Docs checked for widget theme/layout counts, lists, and dimensions against tokens.json. */
const DOC_FILES = [
  "README.md",
  "CLAUDE.md",
  "apps/docs/content/docs/features.mdx",
  "apps/docs/content/docs/widget.mdx",
];

/** Recursively collects files under `dir` whose name ends with `suffix`. */
function walk(dir, suffix, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) walk(full, suffix, out);
    else if (entry.name.endsWith(suffix)) out.push(full);
  }
  return out;
}

/** 1-based line number of character offset `index` in `text`. */
function lineAt(text, index) {
  return text.slice(0, index).split("\n").length;
}

/** Order-insensitive equality for two lists of unique strings. */
function sameMembers(actual, expected) {
  return actual.length === expected.length && expected.every((value) => actual.includes(value));
}

/** Returns the offset just past a Swift block comment starting at `start`; Swift block comments nest. */
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

/** Skips whitespace and `//` / block comments, returning the offset of the next real token. */
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

/** Reads a plain double-quoted Swift string literal at `start`. Returns the raw contents (escapes unprocessed) and the end offset, or null if unterminated. */
function readSwiftString(source, start) {
  let cursor = start + 1;
  while (cursor < source.length) {
    if (source[cursor] === "\\") cursor += 2;
    else if (source[cursor] === '"') return { value: source.slice(start + 1, cursor), end: cursor + 1 };
    else cursor += 1;
  }
  return null;
}

/** Parses `["a", "b"]` starting at the `[`. Returns null unless the bracket holds only string literals, so index subscripts and other arrays are ignored. */
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

/** Finds Swift array literals whose members equal a token-derived group (theme or layout names). Such a copy would drift from tokens.json; comments and strings are skipped. `groups` maps a label to its expected names. */
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

/** Returns the entries of `REQUIRED_HEADINGS` missing from a catalog entry, or out of order (each must appear after the previous one). */
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

/** Compares the `name:` entries of `RULES` in lint.ts against the backticked names in its `* Rules:` comment block, in both directions. */
export function checkLintRuleParity(source) {
  const implemented = [...source.matchAll(/\bname:\s*"([a-z0-9-]+)"/g)].map((match) => match[1]);
  const rulesComment = source.match(/\* Rules:\s*([\s\S]*?)\*\//)?.[1] ?? "";
  const claimed = [...rulesComment.matchAll(/`([a-z0-9-]+)`/g)].map((match) => match[1]);
  return {
    unimplementedClaims: claimed.filter((name) => !implemented.includes(name)),
    undocumentedRules: implemented.filter((name) => !claimed.includes(name)),
  };
}

/** Spelled-out numbers docs may use for counts ("five layouts"); index is the value. */
const NUMBER_WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];

/** Converts a digit string or spelled-out number to a number, or -1 if unrecognised. */
function claimedNumber(raw) {
  const number = Number(raw);
  return Number.isNaN(number) ? NUMBER_WORDS.indexOf(raw.toLowerCase()) : number;
}

/** Finds markdown tables whose header starts with `Layout` and returns their body rows (cells plus 1-based line), skipping the separator row. */
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

/** Checks one docs file against tokens.json: theme/layout counts, inline theme and layout lists, the "selectable themes" sentence, the layout dimension table, and the OBS canvas padding claims. Returns `{ line, message }` failures. */
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

/** Checks landing-page source: any `ws://` / `http://` localhost example must use the real default port for its scheme and must not point at a `now-playing` URL, and the page must not claim an unauthenticated JSON endpoint. */
export function checkLandingProtocol(text, { webSocketPort, widgetPort }) {
  const failures = [];
  for (const match of text.matchAll(/\b(ws|http):\/\/(?:localhost|mac\.local):(\d+)([^\s"'<>`]*)/g)) {
    const expected = match[1] === "ws" ? webSocketPort : widgetPort;
    if (Number(match[2]) !== expected || /now-playing/.test(match[3])) {
      failures.push({ line: lineAt(text, match.index), message: "landing example does not match the local server protocol" });
    }
  }
  if (/no auth gymnastics|now-playing\.json/.test(text)) {
    failures.push({ line: 1, message: "landing claims an unsupported unauthenticated JSON endpoint" });
  }
  return failures;
}

/**
 * Ports that legitimately appear in the docs but are not WolfWave's servers,
 * so `checkDocPorts` must not hold them to the AppConstants defaults. Add a
 * port here (with what owns it) rather than rewording a correct doc.
 */
export const FOREIGN_DOC_PORTS = new Set([
  3000, // the docs site's own `bun run dev` server
]);

/**
 * Flags a WebSocket or widget-HTTP port in docs prose that differs from the
 * AppConstants defaults. A port is read from `scheme://host:N`, `port N`, or
 * `host:N`; the line's own wording (websocket/ws vs http/widget/shell) picks
 * which default it must equal, and a line naming both accepts either.
 */
export function checkDocPorts(text, { webSocketPort, widgetPort }) {
  const failures = [];
  const lines = text.split("\n");
  lines.forEach((line, index) => {
    const ports = [];
    for (const match of line.matchAll(/\b(ws|wss|http|https):\/\/[^\s"'<>`/:]+:(\d{4,5})\b/g)) {
      ports.push({ port: Number(match[2]), kind: match[1].startsWith("ws") ? "ws" : "http" });
    }
    const bare = line.replace(/\b(?:ws|wss|http|https):\/\/[^\s"'<>`]+/g, "");
    for (const match of bare.matchAll(/(?:\bport\s+`?|`?[\w.]*:)(\d{4,5})\b/gi)) {
      ports.push({ port: Number(match[1]), kind: null });
    }
    for (const { port, kind } of ports) {
      if (port < 1024 || FOREIGN_DOC_PORTS.has(port)) continue;
      const mentionsWs = /web\s?socket|\bwss?\b/i.test(line);
      const mentionsHttp = /\bhttp\b|widget|shell/i.test(line);
      let allowed;
      if (kind === "ws") allowed = [webSocketPort];
      else if (kind === "http") allowed = [widgetPort];
      else if (mentionsWs && !mentionsHttp) allowed = [webSocketPort];
      else if (mentionsHttp && !mentionsWs) allowed = [widgetPort];
      else allowed = [webSocketPort, widgetPort];
      if (!allowed.includes(port)) {
        failures.push({ line: index + 1, message: `port ${port} does not match the AppConstants default (${allowed.join(" or ")})` });
      }
    }
  });
  return failures;
}

/**
 * Checks that every field id `BugReportURL.FormField` prefills names a text
 * field (`input` or `textarea`) in the bug report issue form. GitHub ignores a
 * query parameter that matches no field, so a rename on either side silently
 * drops that value from every in-app bug report. A dropdown can't be prefilled
 * from a URL, so naming one fails too.
 */
export function checkBugReportFields(swiftSource, formYaml) {
  const block = /enum FormField\s*\{([\s\S]*?)\n\s*\}/.exec(swiftSource);
  if (!block) return [{ line: 1, message: "BugReportURL.FormField not found" }];
  const textFields = new Set();
  for (const element of formYaml.split(/\n\s*-\s*type:\s*/).slice(1)) {
    const type = /^(\w+)/.exec(element)?.[1];
    const id = /\n\s*id:\s*([\w-]+)/.exec(element)?.[1];
    if (id && (type === "input" || type === "textarea")) textFields.add(id);
  }
  const bodyStart = block.index + block[0].indexOf(block[1]);
  const failures = [];
  for (const match of block[1].matchAll(/static let \w+ = "([^"]+)"/g)) {
    if (textFields.has(match[1])) continue;
    failures.push({
      line: lineAt(swiftSource, bodyStart + match.index),
      message: `prefills "${match[1]}", but bug_report.yml has no input or textarea with that id`,
    });
  }
  return failures;
}

/** Reads the source-of-truth values the checks compare against: visible theme names, layout names and sizes (tokens.json), and the viewport padding and default ports parsed out of AppConstants.swift. Throws if the padding can't be found. */
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
  const webSocketPort = Number(appConstants.match(/static let defaultPort: UInt16 = (\d+)/)?.[1]);
  const widgetPort = Number(appConstants.match(/static let widgetDefaultPort: UInt16 = (\d+)/)?.[1]);
  return { themes, layouts, layoutSizes, viewportPadding, webSocketPort, widgetPort };
}

/** Verifies the component catalog: every Swift view under `COMPONENT_ROOTS` has an entry, every entry names an existing covered source, follows the heading template, and is listed in the catalog README index (and vice versa). */
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

/** Runs every sync check against the tree at `root` and returns all failures as `{ file, line, message }`. Pure aside from reading files, so tests can point it at a fixture tree. */
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

  for (const file of ["apps/docs/app/(home)/page.tsx", "apps/docs/app/(home)/DeveloperTabs.tsx"]) {
    const text = readFileSync(resolve(root, file), "utf8");
    for (const failure of checkLandingProtocol(text, expected)) failures.push({ file, ...failure });
  }

  for (const file of DOC_FILES) {
    const text = readFileSync(resolve(root, file), "utf8");
    for (const failure of checkDocsText(text, expected)) failures.push({ file, ...failure });
  }

  const portDocs = [
    ...walk(resolve(root, "apps/docs/content/docs"), ".mdx").filter((file) => !file.endsWith("changelog.mdx")),
    ...walk(resolve(root, "apps/native/docs"), ".md"),
  ];
  for (const file of portDocs) {
    for (const failure of checkDocPorts(readFileSync(file, "utf8"), expected)) {
      failures.push({ file: relative(root, file), ...failure });
    }
  }

  const lintFile = "design-system/scripts/lint.ts";
  const parity = checkLintRuleParity(readFileSync(resolve(root, lintFile), "utf8"));
  for (const name of parity.unimplementedClaims) failures.push({ file: lintFile, line: 1, message: `comment claims unimplemented rule ${name}` });
  for (const name of parity.undocumentedRules) failures.push({ file: lintFile, line: 1, message: `RULES entry ${name} is missing from the Rules comment` });

  const bugReportURL = "apps/native/WolfWave/Core/BugReportURL.swift";
  const bugReportFailures = checkBugReportFields(
    readFileSync(resolve(root, bugReportURL), "utf8"),
    readFileSync(resolve(root, ".github/ISSUE_TEMPLATE/bug_report.yml"), "utf8"),
  );
  for (const failure of bugReportFailures) failures.push({ file: bugReportURL, ...failure });
  return failures;
}

if (resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  const failures = runChecks();
  if (failures.length === 0) {
    console.log("✅ Source-derived lists, component catalog, docs values, lint claims, and bug-report form fields are in sync.");
    process.exit(0);
  }
  for (const failure of failures) {
    const message = `${failure.file}:${failure.line}: ${failure.message}`;
    console.log(process.env.GITHUB_ACTIONS ? `::error file=${failure.file},line=${failure.line}::${failure.message}` : message);
  }
  console.log(`\n❌ ${failures.length} sync problem(s). Run make lint-sync after updating source or docs.`);
  process.exit(1);
}
