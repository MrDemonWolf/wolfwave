//
//  version.test.mjs
//  WolfWave
//
//  Exercises scripts/version.sh inside throwaway git repos: the shallow-clone
//  guard, tag parsing, marketing-version validation, the build floor, and the
//  stable/nightly channel output. version.sh cd's to its own repo root, so each
//  test copies the script into a scratch repo with a minimal pbxproj.
//
//  Run: node --test scripts/version.test.mjs
//

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const realScript = fileURLToPath(new URL("./version.sh", import.meta.url));

const git = (cwd, ...args) =>
  execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "t",
      GIT_AUTHOR_EMAIL: "t@example.com",
      GIT_COMMITTER_NAME: "t",
      GIT_COMMITTER_EMAIL: "t@example.com",
    },
  });

/// Builds a scratch repo with `commits` commits and the given committed
/// MARKETING_VERSION. Returns { dir, run(args, env) }.
function makeRepo({ commits = 3, marketing = "1.2.3" } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "version-sh-"));
  git(dir, "init", "-q", "-b", "main");
  git(dir, "config", "commit.gpgsign", "false");
  mkdirSync(join(dir, "scripts"));
  copyFileSync(realScript, join(dir, "scripts", "version.sh"));
  mkdirSync(join(dir, "apps/native/WolfWave.xcodeproj"), { recursive: true });
  writeFileSync(
    join(dir, "apps/native/WolfWave.xcodeproj/project.pbxproj"),
    `\t\t\t\tMARKETING_VERSION = ${marketing};\n`
  );
  git(dir, "add", "-A");
  for (let i = 0; i < commits; i++) {
    git(dir, "commit", "-q", "--allow-empty", "-m", `c${i}`);
  }
  const run = (args = [], env = {}) =>
    spawnSync("bash", [join(dir, "scripts", "version.sh"), ...args], {
      cwd: dir,
      encoding: "utf8",
      env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env },
    });
  return { dir, run, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test("stable channel: json output, committed marketing version, floored build", () => {
  const repo = makeRepo({ commits: 3, marketing: "1.2.3" });
  try {
    const r = repo.run();
    assert.equal(r.status, 0, r.stderr);
    const out = JSON.parse(r.stdout);
    assert.equal(out.marketing, "1.2.3");
    assert.equal(out.channel, "stable");
    // 3 commits is below the floor, so the floor wins.
    assert.equal(out.build, 100);
    assert.match(out.short_sha, /^[0-9a-f]{7,}$/);
  } finally {
    repo.cleanup();
  }
});

test("build number is the commit count once it clears the floor", () => {
  const repo = makeRepo({ commits: 105 });
  try {
    const r = repo.run();
    assert.equal(r.status, 0, r.stderr);
    assert.equal(JSON.parse(r.stdout).build, 105);
  } finally {
    repo.cleanup();
  }
});

test("--format env emits KEY=value lines", () => {
  const repo = makeRepo();
  try {
    const r = repo.run(["--format", "env"]);
    assert.equal(r.status, 0, r.stderr);
    const lines = r.stdout.trim().split("\n");
    assert.deepEqual(
      lines.map((l) => l.split("=")[0]),
      ["marketing", "build", "short_sha", "channel"]
    );
    assert.ok(lines.includes("marketing=1.2.3"));
    assert.ok(lines.includes("channel=stable"));
  } finally {
    repo.cleanup();
  }
});

test("nightly channel appends -nightly+<sha> to the marketing version", () => {
  const repo = makeRepo();
  try {
    const r = repo.run(["--channel", "nightly"]);
    assert.equal(r.status, 0, r.stderr);
    const out = JSON.parse(r.stdout);
    assert.equal(out.channel, "nightly");
    assert.equal(out.marketing, `1.2.3-nightly+${out.short_sha}`);
  } finally {
    repo.cleanup();
  }
});

test("nightly warns when MARKETING_VERSION equals the newest shipped tag", () => {
  const repo = makeRepo({ marketing: "1.2.3" });
  try {
    git(repo.dir, "tag", "v1.2.3");
    const r = repo.run(["--channel", "nightly"]);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stderr, /WARNING/);
  } finally {
    repo.cleanup();
  }
});

test("a v* tag ref overrides the committed marketing version", () => {
  const repo = makeRepo({ marketing: "1.2.3" });
  try {
    const r = repo.run([], { GITHUB_REF: "refs/tags/v4.5.6" });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(JSON.parse(r.stdout).marketing, "4.5.6");
  } finally {
    repo.cleanup();
  }
});

test("a malformed tag is rejected", () => {
  const repo = makeRepo();
  try {
    for (const bad of ["refs/tags/v2.1", "refs/tags/vfoo", "refs/tags/v01.2.3"]) {
      const r = repo.run([], { GITHUB_REF: bad });
      assert.notEqual(r.status, 0, bad);
      assert.match(r.stderr, /MAJOR\.MINOR\.PATCH/);
    }
  } finally {
    repo.cleanup();
  }
});

test("MARKETING_VERSION_OVERRIDE wins over the tag", () => {
  const repo = makeRepo();
  try {
    const r = repo.run([], {
      MARKETING_VERSION_OVERRIDE: "7.8.9",
      GITHUB_REF: "refs/tags/v4.5.6",
    });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(JSON.parse(r.stdout).marketing, "7.8.9");
  } finally {
    repo.cleanup();
  }
});

test("a shallow clone is refused", () => {
  const origin = makeRepo({ commits: 5 });
  const clone = mkdtempSync(join(tmpdir(), "version-sh-shallow-"));
  try {
    execFileSync(
      "git",
      ["clone", "-q", "--depth", "1", `file://${origin.dir}`, join(clone, "r")],
      { encoding: "utf8" }
    );
    const r = spawnSync("bash", [join(clone, "r", "scripts", "version.sh")], {
      cwd: join(clone, "r"),
      encoding: "utf8",
    });
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /shallow clone/);
    assert.equal(r.stdout, "");
  } finally {
    origin.cleanup();
    rmSync(clone, { recursive: true, force: true });
  }
});

test("bad --channel and --format are usage errors", () => {
  const repo = makeRepo();
  try {
    assert.equal(repo.run(["--channel", "beta"]).status, 2);
    assert.equal(repo.run(["--format", "xml"]).status, 2);
    assert.equal(repo.run(["--bogus"]).status, 2);
  } finally {
    repo.cleanup();
  }
});
