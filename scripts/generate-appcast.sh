#!/usr/bin/env bash
#
# Generate and validate a Sparkle appcast for the DMGs in a build directory.
#
# Uses the tool bundled with the resolved (pinned) Sparkle package. Outside CI a
# Homebrew install is an accepted fallback. Set SPARKLE_BIN to a full path to
# bypass the lookup.
#
# Env:
#   SPARKLE_PRIVATE_KEY  the EdDSA private key (repo secret)
#
# Usage: scripts/generate-appcast.sh <output-xml> <download-url-prefix> [builds-dir]

set -euo pipefail

output="${1:?usage: generate-appcast.sh <output-xml> <download-url-prefix> [builds-dir]}"
url_prefix="${2:?missing download-url-prefix}"
builds_dir="${3:-builds}"

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"

# The CLI must match the Sparkle framework the app links (pinned in
# Package.resolved), because generate_appcast and the in-app updater share the
# appcast format and EdDSA handling. In CI the SPM artifact is the ONLY accepted
# source: a runner-image Homebrew Sparkle would be an unpinned, unreviewed
# version. Locally a Homebrew install is an acceptable fallback.
spm_bin_dir="SourcePackages/artifacts/sparkle/Sparkle/bin"

find_tool() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    find "$spm_bin_dir" -name generate_appcast -type f 2>/dev/null | head -1 || true
  else
    find "$spm_bin_dir" \
      /opt/homebrew/Caskroom/sparkle /usr/local/Caskroom/sparkle \
      -name generate_appcast -type f 2>/dev/null | head -1 || true
  fi
}

tool="${SPARKLE_BIN:-}"
if [ -z "$tool" ]; then
  tool="$(find_tool)"
fi
if [ -z "$tool" ]; then
  echo "::error::Could not locate generate_appcast under $spm_bin_dir; resolve Sparkle package dependencies (xcodebuild -clonedSourcePackagesDirPath SourcePackages) or set SPARKLE_BIN" >&2
  exit 1
fi
echo "Using $tool"

key_file="$(mktemp)"
trap 'rm -f "$key_file"' EXIT
printf '%s\n' "$SPARKLE_PRIVATE_KEY" > "$key_file"

# --embed-release-notes forces the notes INLINE into <description>. Without it,
# generate_appcast refuses to embed a full HTML document (release-notes.mjs
# emits <!DOCTYPE>/<body>) and instead writes a <sparkle:releaseNotesLink> to
# the .html release asset. GitHub serves release assets as
# `Content-Disposition: attachment`, so Sparkle's web view downloads the file
# instead of rendering it.
"$tool" \
  --ed-key-file "$key_file" \
  --embed-release-notes \
  --download-url-prefix "$url_prefix" \
  -o "$output" "$builds_dir/"

xmllint --noout "$output"

fail() { echo "::error::$1" >&2; exit 1; }

grep -q 'sparkle:edSignature=' "$output" \
  || fail "$output has no edSignature; the update would be rejected as unsigned"
grep -q '<description>' "$output" \
  || fail "$output has no inline <description> release notes"
# Hard guard: notes MUST be inline. A <sparkle:releaseNotesLink> means embedding
# failed and Sparkle will download the notes instead of rendering them.
if grep -q 'releaseNotesLink' "$output"; then
  fail "$output has a releaseNotesLink; the notes were not embedded"
fi

echo "Appcast generated and validated: $output"
