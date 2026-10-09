#!/usr/bin/env bash
# nightly-gate.sh — decide whether the gfx1103 nightly has to rebuild.
#
# "Only build when there is a new version", expressed as a decision ladder. The previous build
# state is read back from the nightly GitHub release, so the gate needs no extra storage and
# survives Actions cache eviction. Every branch writes an auditable reason into the run summary;
# the outputs are consumed by the build job.
#
# Inputs (environment):
#   UPSTREAM_REPO      llama.cpp repo to track            (default ggml-org/llama.cpp)
#   UPSTREAM_REF       branch / tag / sha to track         (default master)
#   RELEASE_TAG        release holding the previous state  (default nightly-gfx1103)
#   GITHUB_REPOSITORY  own repo (owner/name); empty => no state lookup (treated as first run)
#   EVENT_NAME         workflow_dispatch bypasses the gate (manual == explicit intent)
#   FORCE_REBUILD      true forces a build
#   PIN_THEROCK        pin an exact TheRock tarball version (skips index detection)
#   MIN_INTERVAL_HOURS min gap between builds driven only by upstream commits (default 72)
#   MAX_STALE_HOURS    force a build after this long without one (default 168)
#   THEROCK_INDEX_URL  AMD tarball index (default https://nightly.repo.amd.com/rocm/core/tarball/)
# Outputs ($GITHUB_OUTPUT): should_build, reason, upstream_repo, upstream_ref, upstream_sha,
#   therock_version, last_sha, gap_hours
#
# Needs only bash + coreutils + `gh` (all present on ubuntu-latest); no local jq required.
set -uo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-ggml-org/llama.cpp}"
UPSTREAM_REF="${UPSTREAM_REF:-master}"
RELEASE_TAG="${RELEASE_TAG:-nightly-gfx1103}"
EVENT_NAME="${EVENT_NAME:-schedule}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"
PIN_THEROCK="${PIN_THEROCK:-}"
MIN_INTERVAL_HOURS="${MIN_INTERVAL_HOURS:-72}"
MAX_STALE_HOURS="${MAX_STALE_HOURS:-168}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

# A change is worth a rebuild when it can alter the shipped HIP package.
WATCHED_PREFIXES=(
  "ggml/"
  "src/"
  "include/"
  "common/"
  "tools/"
  "examples/server/"
  "examples/main/"
  "CMakeLists.txt"
  "version"
)
# Backends that are not compiled into this HIP-only package: their churn alone is not a reason
# to spend ~30 minutes of Windows runner time.
IGNORED_PREFIXES=(
  "ggml/src/ggml-cuda/"
  "ggml/src/ggml-metal/"
  "ggml/src/ggml-sycl/"
  "ggml/src/ggml-opencl/"
  "ggml/src/ggml-webgpu"
  "ggml/src/ggml-rpc"
  "ggml/src/ggml-zute/"
)
DOC_SUFFIXES=(".md" ".txt" ".png" ".jpg" ".jpeg" ".gif" ".svg")

out() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
  fi
}

log() { printf '[gate] %s\n' "$*"; }

is_relevant() {
  local f="$1" s p
  for s in "${DOC_SUFFIXES[@]}"; do
    case "$f" in *"$s") return 1 ;; esac
  done
  for p in "${IGNORED_PREFIXES[@]}"; do
    case "$f" in "$p"*) return 1 ;; esac
  done
  for p in "${WATCHED_PREFIXES[@]}"; do
    case "$f" in "$p"*) return 0 ;; esac
  done
  return 1
}

# marker field extraction: {"sha":"...","therock":"...","built_at":"..."}
marker_field() {
  printf '%s' "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# newest 10.x tarball version from the AMD index, e.g. 10.2.0a20261008
detect_therock() {
  curl -sS --max-time 60 "$1" 2>/dev/null |
    grep -oE 'therock-dist-windows-gfx110X-all-[0-9][^"]*\.tar\.gz' |
    sed -E 's|^therock-dist-windows-gfx110X-all-||; s|\.tar\.gz$||' |
    sort -uV | tail -1
}

# strip the daily build suffix: 10.2.0a20261008 -> 10.2.0
base_version() {
  printf '%s' "${1:-}" | sed -E 's/a[0-9]{8}$//'
}

show_summary() {
  local verdict="$1" reason="$2" word
  if [ "$verdict" = true ]; then word="BUILD"; else word="SKIP"; fi
  summary "### gfx1103 nightly gate: ${word}"
  summary ""
  summary "| item | value |"
  summary "| --- | --- |"
  summary "| decision | ${word} — ${reason} |"
  summary "| upstream | \`${UPSTREAM_REPO}@${UPSTREAM_REF}\` = \`${HEAD_SHA:-n/a}\` |"
  summary "| last built | \`${LAST_SHA:-none}\` / TheRock \`${LAST_THEROCK:-unknown}\` / ${LAST_BUILT_AT:-?} |"
  summary "| newest TheRock | \`${THEROCK_VERSION:-unknown}\` (base ${THEROCK_BASE:-n/a}) |"
  summary "| diff | status=\`${CMP_STATUS:-n/a}\` commits=${CMP_TOTAL:-0} files=${CMP_FILES:-0} relevant=${RELEVANT:-0} |"
  summary "| gap | ${GAP_HOURS:-?}h (min interval ${MIN_INTERVAL_HOURS}h, stale guard ${MAX_STALE_HOURS}h) |"
}

decide() {
  local verdict="$1" reason="$2"
  out "should_build" "$verdict"
  out "reason" "$reason"
  log "verdict=${verdict} reason=${reason}"
  show_summary "$verdict" "$reason"
  exit 0
}

# -------------------------------------------------------------- upstream HEAD
if ! HEAD_SHA="$(gh api "repos/${UPSTREAM_REPO}/commits/${UPSTREAM_REF}" --jq '.sha' 2>/dev/null)" ||
  [ -z "$HEAD_SHA" ]; then
  log "ERROR: cannot resolve ${UPSTREAM_REPO}@${UPSTREAM_REF}"
  out "upstream_repo" "$UPSTREAM_REPO"
  out "upstream_ref" "$UPSTREAM_REF"
  out "should_build" "false"
  out "reason" "upstream-ref-unresolvable"
  summary "### gfx1103 nightly gate: FAIL — cannot resolve \`${UPSTREAM_REPO}@${UPSTREAM_REF}\`"
  exit 1
fi
out "upstream_repo" "$UPSTREAM_REPO"
out "upstream_ref" "$UPSTREAM_REF"
out "upstream_sha" "$HEAD_SHA"
log "upstream HEAD = ${HEAD_SHA}"

# -------------------------------------------- previous build state (nightly release)
LAST_SHA=""
LAST_THEROCK=""
LAST_BUILT_AT=""
if [ -n "$GITHUB_REPOSITORY" ]; then
  # gh --jq yields the decoded string, so the body is handled as plain text.
  BODY="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${RELEASE_TAG}" --jq '.body // ""' 2>/dev/null || true)"
  if [ -n "$BODY" ]; then
    MARKER="$(printf '%s\n' "$BODY" | grep -oE 'ci-build-state: \{[^}]*\}' | tail -1 | sed 's/^ci-build-state: //')"
    if [ -n "$MARKER" ]; then
      LAST_SHA="$(marker_field "$MARKER" sha)"
      LAST_THEROCK="$(marker_field "$MARKER" therock)"
      LAST_BUILT_AT="$(marker_field "$MARKER" built_at)"
    fi
    # Releases published before the marker existed only carry the commit inside the notes.
    if [ -z "$LAST_SHA" ]; then
      LAST_SHA="$(printf '%s\n' "$BODY" | grep -oE 'commit/[0-9a-f]{7,40}' | head -1 | cut -d/ -f2)"
    fi
    if [ -z "$LAST_BUILT_AT" ]; then
      LAST_BUILT_AT="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${RELEASE_TAG}" --jq '.updated_at' 2>/dev/null || true)"
    fi
  fi
fi
log "last built sha=${LAST_SHA:-none} therock=${LAST_THEROCK:-none} at=${LAST_BUILT_AT:-none}"

GAP_HOURS=""
NOW_EPOCH="$(date -u +%s)"
if [ -n "$LAST_BUILT_AT" ]; then
  LAST_EPOCH="$(date -u -d "${LAST_BUILT_AT}" +%s 2>/dev/null || true)"
  if [ -n "$LAST_EPOCH" ]; then
    GAP_HOURS=$(( (NOW_EPOCH - LAST_EPOCH) / 3600 ))
  fi
fi
if [ -z "$GAP_HOURS" ]; then
  GAP_HOURS=999999 # unknown previous build time => treat as very old
fi
out "last_sha" "${LAST_SHA:-}"
out "gap_hours" "$GAP_HOURS"

# ----------------------------------------------------- newest TheRock kpack release
# AMD publishes a new gfx110X tarball every day (10.2.0aYYYYMMDD). A date-only bump is NOT a
# reason to rebuild; only a change of the SDK base version (10.2.0 -> 10.3.0) is.
THEROCK_INDEX_URL="${THEROCK_INDEX_URL:-https://nightly.repo.amd.com/rocm/core/tarball/}"
if [ -n "$PIN_THEROCK" ]; then
  THEROCK_VERSION="$PIN_THEROCK"
else
  THEROCK_VERSION="$(detect_therock "$THEROCK_INDEX_URL")"
fi
THEROCK_BASE="$(base_version "$THEROCK_VERSION")"
LAST_THEROCK_BASE="$(base_version "$LAST_THEROCK")"
out "therock_version" "$THEROCK_VERSION"
log "newest TheRock windows-gfx110X-all tarball = ${THEROCK_VERSION:-none} (base ${THEROCK_BASE:-none}, last built base ${LAST_THEROCK_BASE:-none})"

# ------------------------------------------------------------ decision ladder
if [ "$FORCE_REBUILD" = "true" ] || [ "$EVENT_NAME" = "workflow_dispatch" ]; then
  decide true "manual dispatch or force_rebuild=true"
fi
if [ -z "$LAST_SHA" ]; then
  decide true "first run: no build state found in release '${RELEASE_TAG}'"
fi
if [ "${HEAD_SHA:0:7}" = "${LAST_SHA:0:7}" ]; then
  decide false "no-new-version: upstream HEAD equals the last built commit (${LAST_SHA:0:7})"
fi
if [ -n "$THEROCK_BASE" ] && [ -n "$LAST_THEROCK_BASE" ] && [ "$THEROCK_BASE" != "$LAST_THEROCK_BASE" ]; then
  decide true "new TheRock SDK base version: ${LAST_THEROCK_BASE} -> ${THEROCK_BASE} (tarball ${THEROCK_VERSION})"
fi

# Single API call: one header line with compare metadata, then one line per changed filename.
CMP="$(gh api "repos/${UPSTREAM_REPO}/compare/${LAST_SHA}...${HEAD_SHA}" \
  --jq '["H", (.status // "unknown"), (.total_commits // 0), ((.files // []) | length)] | @tsv, ((.files // [])[] | .filename)' 2>/dev/null || true)"
if [ -z "$CMP" ]; then
  decide true "conservative: compare ${LAST_SHA:0:7}...${HEAD_SHA:0:7} unavailable (non-linear history?)"
fi
CMP_HEADER="$(printf '%s\n' "$CMP" | head -1)"
IFS=$'\t' read -r _ CMP_STATUS CMP_TOTAL CMP_FILES <<<"$CMP_HEADER"
RELEVANT=0
RELEVANT_SAMPLE=""
while IFS= read -r f; do
  if [ -z "$f" ] || [ "${f#H$'\t'}" != "$f" ]; then
    continue
  fi
  if is_relevant "$f"; then
    RELEVANT=$((RELEVANT + 1))
    if [ -z "$RELEVANT_SAMPLE" ]; then
      RELEVANT_SAMPLE="$f"
    fi
  fi
done <<<"$CMP"
log "commits=${CMP_TOTAL} files=${CMP_FILES} relevant=${RELEVANT} status=${CMP_STATUS} gap=${GAP_HOURS}h"

# The compare API truncates its file list at 300 entries, so "no relevant change" cannot be proven.
if [ "${CMP_FILES:-0}" -ge 300 ]; then
  decide true "conservative: diff reports ${CMP_FILES} files (list may be truncated), ${CMP_TOTAL} commits"
fi
if [ "$CMP_STATUS" != "ahead" ] && [ "$CMP_STATUS" != "diverged" ]; then
  decide true "conservative: compare status '${CMP_STATUS}' is not a fast-forward diff"
fi

# The compare API truncates its file list at 300 entries, so "no relevant change" cannot be proven.
if [ "$GAP_HOURS" -ge "$MAX_STALE_HOURS" ]; then
  # Safety net: never go longer than MAX_STALE_HOURS without a package, even if the changed
  # files all look irrelevant (the watch list can miss something, e.g. a dependency bump).
  decide true "stale guard: no build for ${GAP_HOURS}h (>= ${MAX_STALE_HOURS}h), ${RELEVANT} relevant files in ${CMP_TOTAL} commits"
fi
if [ "$RELEVANT" -eq 0 ]; then
  decide false "no-relevant-change: ${CMP_TOTAL} commits / ${CMP_FILES} files, none affect the gfx1103 HIP build"
fi
if [ "$GAP_HOURS" -lt "$MIN_INTERVAL_HOURS" ]; then
  decide false "interval guard: last build ${GAP_HOURS}h ago (< ${MIN_INTERVAL_HOURS}h), ${RELEVANT} relevant files queued for the next run"
fi
decide true "new version: ${RELEVANT} relevant files in ${CMP_TOTAL} commits since ${LAST_SHA:0:7} (first: ${RELEVANT_SAMPLE})"
