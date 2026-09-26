#!/usr/bin/env bash
# Fetch a CI-built arm64 release bundle and extract it as a release snapshot.
#
#   scripts/ci-fetch-bundle.sh                 # newest successful build on master
#   scripts/ci-fetch-bundle.sh <run-id>        # a specific run
#
# The bundle comes from .github/workflows/build-arm64-bundle.yml on a native arm64
# runner, so the Orange Pi never runs the memory-hungry Next.js build. This script only
# STAGES a release; cutting over is a separate explicit step (scripts/cutover-release.sh).
#
# Host-specific realities this script exists to handle:
#   * /tmp is a ~2GB tmpfs and a bundle is ~1GB, so staging must live on real disk.
#   * GitHub download throughput from this host is ~30KB/s per single connection (and it
#     is NOT specific to the artifact CDN: codeload measured ~35KB/s, raw ~5KB/s), while
#     single-stream transfers get reset mid-flight. The CDN does honour ranged requests
#     (HTTP 206), so we pull N ranges in parallel and resume each one.
#   * `gh run download` was observed to hang indefinitely on this host; `gh api .../zip`
#     streams instead.
#   * `unzip` is not installed; extraction uses python3's stdlib zipfile.
set -euo pipefail

REPO="muhajirinlpu/9router"
DEST_ROOT="${DEST_ROOT:-$HOME/9router-releases}"
WORK="${WORK:-$HOME/.cache/9router-ci-fetch}"
PARALLEL="${PARALLEL:-8}"
CHUNK_MB="${CHUNK_MB:-2}"
RUN_ID="${1:-}"

# A bundle needs roughly 3x its compressed size (archive + tar + extracted tree).
mkdir -p "$WORK"
avail_kb=$(df -Pk "$WORK" | awk 'NR==2{print $4}')
if [ "$avail_kb" -lt 3000000 ]; then
  echo "FATAL: need ~3GB free on $(df -Pk "$WORK" | awk 'NR==2{print $6}'), have $((avail_kb/1024))MB"
  exit 2
fi
# Staging persists across runs so a re-run resumes finished chunks instead of restarting.
# It is removed only after a release has been staged and verified (see the end).

TOKEN=$(gh auth token) || { echo "FATAL: gh not authenticated"; exit 2; }

if [ -z "$RUN_ID" ]; then
  echo ">> resolving newest successful run on master"
  RUN_ID=$(gh run list -R "$REPO" --workflow="build-arm64-bundle.yml" \
    --branch master --status success --limit 1 --json databaseId --jq '.[0].databaseId')
fi
[ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] || { echo "FATAL: no successful run found"; exit 2; }
echo ">> run: $RUN_ID"
gh run view "$RUN_ID" -R "$REPO" --json displayTitle,headSha,conclusion \
  --jq '"   title=\(.displayTitle)\n   sha=\(.headSha)\n   conclusion=\(.conclusion)"'

meta=$(gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts")
ARTIFACT_ID=$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["artifacts"][0]["id"])')
ARTIFACT_BYTES=$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["artifacts"][0]["size_in_bytes"])')
ARTIFACT_NAME=$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["artifacts"][0]["name"])')
[ -n "$ARTIFACT_ID" ] || { echo "FATAL: run has no artifact"; exit 2; }
echo ">> artifact $ARTIFACT_ID ($ARTIFACT_NAME) $((ARTIFACT_BYTES/1024/1024))MB"

URL="https://api.github.com/repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip"
PARTS="$WORK/parts"
mkdir -p "$PARTS"

# Staged chunks belong to exactly one artifact; switching must not reuse them.
if [ -f "$WORK/artifact-id" ] && [ "$(cat "$WORK/artifact-id")" != "$ARTIFACT_ID" ]; then
  echo ">> different artifact than staged chunks; resetting staging"
  rm -rf "$PARTS" "$WORK/artifact.zip" "$WORK/unpacked"
fi
printf '%s' "$ARTIFACT_ID" > "$WORK/artifact-id"

# ---- parallel ranged download --------------------------------------------------
CHUNK=$(( CHUNK_MB * 1024 * 1024 ))
NCHUNKS=$(( (ARTIFACT_BYTES + CHUNK - 1) / CHUNK ))
export TOKEN URL PARTS CHUNK ARTIFACT_BYTES

# Small bounded chunks, so a transfer completes before the connection is reset (long
# transfers were timing out part-way). A chunk is published by rename only when it is
# exactly the expected size, so a truncated or stalled read can never be mistaken for a
# finished chunk, and a re-run resumes whatever already completed.
fetch_chunk() {
  idx="$1"
  start=$(( idx * CHUNK ))
  end=$(( start + CHUNK - 1 ))
  [ "$end" -ge "$ARTIFACT_BYTES" ] && end=$(( ARTIFACT_BYTES - 1 ))
  want=$(( end - start + 1 ))
  out="$PARTS/c$idx"

  if [ -f "$out" ] && [ "$(stat -c%s "$out")" = "$want" ]; then
    return 0   # already complete from a previous run
  fi

  for _attempt in 1 2 3 4 5 6 7 8; do
    tmp="$out.partial"
    rm -f "$tmp"
    curl -sSL -H "Authorization: Bearer $TOKEN" --max-time 300 \
      --retry 2 --retry-all-errors --retry-delay 2 \
      --range "${start}-${end}" -o "$tmp" "$URL" 2>/dev/null || true
    if [ "$(stat -c%s "$tmp" 2>/dev/null || echo 0)" = "$want" ]; then
      mv -f "$tmp" "$out"
      return 0
    fi
    rm -f "$tmp"
  done
  return 1
}
export -f fetch_chunk

echo ">> downloading $NCHUNKS chunks of ${CHUNK_MB}MB, $PARALLEL in parallel"
echo "   (throughput to GitHub from this host is low; re-running resumes progress)"

seq 0 $(( NCHUNKS - 1 )) | xargs -P "$PARALLEL" -I{} bash -c 'fetch_chunk {}' || true

# Report partial progress honestly rather than failing opaquely.
missing=0
for i in $(seq 0 $(( NCHUNKS - 1 ))); do
  start=$(( i * CHUNK )); end=$(( start + CHUNK - 1 ))
  [ "$end" -ge "$ARTIFACT_BYTES" ] && end=$(( ARTIFACT_BYTES - 1 ))
  want=$(( end - start + 1 ))
  [ "$(stat -c%s "$PARTS/c$i" 2>/dev/null || echo 0)" = "$want" ] || missing=$(( missing + 1 ))
done
echo ">> chunks complete: $(( NCHUNKS - missing ))/$NCHUNKS"
if [ "$missing" -ne 0 ]; then
  echo "FATAL: $missing chunk(s) incomplete. Staging kept at $WORK - re-run to resume."
  exit 2
fi

# ---- reassemble in order, verify exact byte count -----------------------------
rm -f "$WORK/artifact.zip"
for i in $(seq 0 $(( NCHUNKS - 1 ))); do
  cat "$PARTS/c$i" >> "$WORK/artifact.zip"
done
got=$(stat -c%s "$WORK/artifact.zip")
echo ">> archive assembled: $got bytes"
[ "$got" = "$ARTIFACT_BYTES" ] || { echo "FATAL: archive size mismatch (want $ARTIFACT_BYTES)"; exit 2; }

# Integrity gate before extraction. Size alone does NOT prove correctness: a chunked
# download can assemble to the right byte count while individual chunks are shifted,
# which yields a broken tree only discovered at runtime. zipfile verifies each member's
# CRC here, so corruption fails fast and loudly instead of silently.
echo ">> verifying archive integrity (CRCs)"
python3 - "$WORK/artifact.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    bad = z.testzip()
    if bad is not None:
        print("FATAL: corrupt member in archive: %s" % bad)
        sys.exit(2)
print("archive CRC check passed (%d entries)" % len(z.namelist()))
PY

# ---- unpack (no unzip on this host) ------------------------------------------
mkdir -p "$WORK/unpacked"
python3 - "$WORK/artifact.zip" "$WORK/unpacked" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
    z.extractall(sys.argv[2])
print("unpacked %d entries" % len(names))
PY

tarball=$(find "$WORK/unpacked" -name '*.tar.gz' | head -1)
[ -n "$tarball" ] || { echo "FATAL: no tarball in artifact"; exit 2; }
name=$(basename "$tarball" .tar.gz)

# Verify the published digest. The digest file records a CI-side absolute path, so
# compare digests directly instead of using `sha256sum -c`.
shafile=$(find "$WORK/unpacked" -name '*.sha256' | head -1)
if [ -n "$shafile" ]; then
  expected=$(awk '{print $1}' "$shafile")
  actual=$(sha256sum "$tarball" | awk '{print $1}')
  echo ">> sha256 expected=$expected"
  echo ">> sha256 actual  =$actual"
  [ "$expected" = "$actual" ] || { echo "FATAL: sha256 mismatch"; exit 2; }
fi

stamp=$(date +%Y%m%d-%H%M%S)
release="$DEST_ROOT/${name}-${stamp}"
echo ">> extracting -> $release"
mkdir -p "$release"
tar xzf "$tarball" -C "$release"

# ---- post-extract gates: a broken bundle must never reach cutover -------------
gate() { echo "FATAL: $1"; rm -rf "$release"; exit 2; }
test -s "$release/custom-server.js" || gate "custom-server.js missing"
test -s "$release/.next/BUILD_ID" || gate "BUILD_ID missing"
test -s "$release/.next/standalone/custom-server.js" || gate "standalone server missing"
test -d "$release/.next/standalone/.next/static" || gate "standalone static missing"
test -d "$release/.next/standalone/public" || gate "standalone public missing"
test -d "$release/node_modules" || gate "node_modules missing"

x64=$(find "$release/node_modules" \( -name '*x64*.node' -o -name '*x86_64*.node' \) | wc -l)
arm=$(find "$release/node_modules" -name '*arm64*.node' | wc -l)
[ "$x64" -eq 0 ] || gate "x86_64 bindings present (unusable on the Pi)"
[ "$arm" -ge 4 ] || gate "too few arm64 bindings ($arm)"

# Only a fully staged, verified release justifies dropping the staging area.
rm -rf "$WORK"

ver=$(node -p "require('$release/package.json').version")
printf '\nREADY version=%s build_id=%s arm64_bindings=%s x64_bindings=%s\n' \
  "$ver" "$(cat "$release/.next/BUILD_ID")" "$arm" "$x64"
printf 'RELEASE=%s\n' "$release"
printf 'Staged only, NOT live. Next: bash scripts/cutover-release.sh "%s"\n' "$release"
