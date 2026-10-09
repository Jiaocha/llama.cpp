#!/usr/bin/env bash
# test-nightly-gate.sh — deterministic unit tests for nightly-gate.sh, using stubbed gh/curl.
#
# Run with a real bash (Git Bash on Windows or the ubuntu runner image):
#   bash .github/scripts/test-nightly-gate.sh
#
# Each case drives exactly one branch of the decision ladder and asserts should_build + reason.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SRC="$HERE/nightly-gate.sh"
[ -f "$GATE_SRC" ] || { echo "FATAL: $GATE_SRC not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cp "$GATE_SRC" "$WORK/nightly-gate.sh"

# --- stub GitHub CLI: answers only the 3 endpoints the gate calls ---------------------------
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
path="${1:-}"; shift || true
jqexpr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqexpr="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$sub" in
  api) ;;
  *) echo "stub(gh): unhandled subcommand: $sub" >&2; exit 2 ;;
esac
case "$path" in
  *"/commits/"*)
    [ "${SC_HEAD_FAIL:-}" = "1" ] && exit 1
    printf '%s\n' "${SC_HEAD:-}" ;;
  *"/releases/tags/"*)
    case "$jqexpr" in
      *".body"*) printf '%s\n' "${SC_BODY:-}" ;;
      *) printf '%s\n' "${SC_UPDATED:-}" ;;
    esac ;;
  *"/compare/"*)
    [ "${SC_CMP_FAIL:-}" = "1" ] && exit 1
    printf '%s\n' "${SC_CMP:-}" ;;
  *) echo "stub(gh): unhandled path: $path" >&2; exit 2 ;;
esac
STUB

# --- stub AMD tarball index (curl) ----------------------------------------------------------
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ "${SC_THEROCK_FAIL:-}" = "1" ] && exit 1
printf 'const files = ['
first=1
for v in ${SC_THEROCK_LIST:-}; do
  [ $first -eq 0 ] && printf ', '
  first=0
  printf '{"name": "therock-dist-windows-gfx110X-all-%s.tar.gz", "mtime": 1.0}' "$v"
done
printf '];\n'
STUB
chmod +x "$WORK/bin/gh" "$WORK/bin/curl"

PASS=0
FAIL=0
FAILED_CASES=""

cmp_with() { # status total nfiles file...
  local status="$1" total="$2" nfiles="$3"
  shift 3
  printf 'H\t%s\t%s\t%s\n' "$status" "$total" "$nfiles"
  printf '%s\n' "$@"
}

SHA_OLD="1111111111111111111111111111111111111111"
SHA_NEW="2222222222222222222222222222222222222222"
NOW="$(date -u +%s)"
ago() { date -u -d "@$((NOW - $1 * 3600))" +%Y-%m-%dT%H:%M:%SZ; }
body_at() { # built_at; last built therock stays 10.2.0a20261001
  printf '### notes\n<!-- ci-build-state: {"sha":"%s","therock":"10.2.0a20261001","built_at":"%s"} -->\n' \
    "$SHA_OLD" "$1"
}
LEGACY_BODY="**llama.cpp Commit**: [\`1111111\`](https://github.com/ggml-org/llama.cpp/commit/$SHA_OLD)
**TheRock ROCm SDK**: \`10.2.0a20261008\`"
# same SDK base version, newer daily tarball -> must NOT trigger a rebuild
IDX_SAME_BASE="10.1.0a20260901 10.2.0a20261008"

BASE_ENV=(UPSTREAM_REPO=ggml-org/llama.cpp UPSTREAM_REF=master RELEASE_TAG=nightly-gfx1103
  GITHUB_REPOSITORY=Jiaocha/llama.cpp MIN_INTERVAL_HOURS=72 MAX_STALE_HOURS=168
  EVENT_NAME=schedule)

# run_case <name> <want_should_build|rc> <want_reason_prefix> [VAR=value ...]
run_case() {
  local name="$1" want_build="$2" want_reason="$3"
  shift 3
  unset SC_HEAD SC_HEAD_FAIL SC_BODY SC_UPDATED SC_CMP SC_CMP_FAIL SC_THEROCK_LIST SC_THEROCK_FAIL
  local out="$WORK/out" sum="$WORK/sum" rc=0
  : >"$out"
  : >"$sum"
  PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$sum" \
    env "${BASE_ENV[@]}" "$@" bash "$WORK/nightly-gate.sh" >"$WORK/stdout" 2>&1 || rc=$?
  local got_build got_reason ok
  got_build="$(sed -n 's/^should_build=//p' "$out" | tail -1)"
  got_reason="$(sed -n 's/^reason=//p' "$out" | tail -1)"
  if [ "$want_build" = "rc" ]; then
    if [ "$rc" -eq 1 ] && [ "$got_build" = "false" ]; then
      PASS=$((PASS + 1)); printf 'PASS  %-30s hard-fail rc=1 (no build)\n' "$name"
    else
      FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES $name"
      printf 'FAIL  %-30s want rc=1 got rc=%s should_build=%s\n' "$name" "$rc" "$got_build"
      sed 's|^|        out: |' "$WORK/stdout"
    fi
    return
  fi
  ok=1
  [ "$got_build" = "$want_build" ] || ok=0
  [ "$rc" -eq 0 ] || ok=0
  case "$got_reason" in "$want_reason"*) ;; *) ok=0 ;; esac
  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-30s %-5s %s\n' "$name" "$got_build" "$got_reason"
    LAST_SUMMARY="$sum"
  else
    FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES $name"
    printf 'FAIL  %-30s want=(%s,"%s") got=(%s,"%s") rc=%s\n' \
      "$name" "$want_build" "$want_reason" "$got_build" "$got_reason" "$rc"
    sed 's|^|        out: |' "$WORK/stdout"
  fi
}

echo "== nightly-gate.sh decision ladder =="
echo "   bash=$BASH_VERSION  sort=$(sort --version 2>/dev/null | head -1)"

run_case "unresolvable-ref" rc "" SC_HEAD_FAIL=1 SC_HEAD=""
run_case "manual-dispatch" true "manual dispatch" \
  SC_HEAD="$SHA_NEW" EVENT_NAME=workflow_dispatch SC_BODY="$(body_at "$(ago 1)")"
run_case "force-rebuild" true "manual dispatch" \
  SC_HEAD="$SHA_NEW" FORCE_REBUILD=true SC_BODY="$(body_at "$(ago 1)")" \
  SC_THEROCK_LIST="$IDX_SAME_BASE" SC_CMP="$(cmp_with ahead 3 1 ggml/src/ggml-hip/foo.c)"
run_case "first-run-no-release" true "first run" SC_HEAD="$SHA_NEW" SC_BODY=""
run_case "first-run-body-without-sha" true "first run" \
  SC_HEAD="$SHA_NEW" SC_BODY="just text" SC_UPDATED="$(ago 5)"
run_case "no-new-version" false "no-new-version" SC_HEAD="$SHA_OLD" SC_BODY="$(body_at "$(ago 2)")"

# TheRock: base version bump builds, daily tarball refresh alone does not
run_case "therock-base-bump" true "new TheRock SDK base version" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="10.2.0a20261008 10.3.0a20261008" SC_BODY="$(body_at "$(ago 1)")"
run_case "therock-date-only-bump" false "interval guard" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" SC_BODY="$(body_at "$(ago 1)")" \
  SC_CMP="$(cmp_with ahead 20 2 ggml/src/ggml-hip/a.c README.md)"
run_case "therock-index-unreachable" false "interval guard" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_FAIL=1 SC_BODY="$(body_at "$(ago 1)")" \
  SC_CMP="$(cmp_with ahead 20 2 ggml/src/ggml-hip/a.c README.md)"
run_case "therock-version-sort-numeric" true "new TheRock SDK base version" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="10.2.0a20261008 10.10.0a20260101" SC_BODY="$(body_at "$(ago 1)")"

# legacy release notes without the marker: commit parsed from the commit link
run_case "legacy-body-parsed" false "interval guard" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" SC_BODY="$LEGACY_BODY" SC_UPDATED="$(ago 10)" \
  SC_CMP="$(cmp_with ahead 25 3 README.md ggml/src/ggml-cuda/kernel.cu ggml/src/ggml-hip/hip.c)"

run_case "interval-guard" false "interval guard" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" SC_BODY="$(body_at "$(ago 10)")" \
  SC_CMP="$(cmp_with ahead 25 3 README.md ggml/src/ggml-cuda/kernel.cu tools/run/llama-bench.cpp)"
run_case "relevant-build" true "new version" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" SC_BODY="$(body_at "$(ago 100)")" \
  SC_CMP="$(cmp_with ahead 25 3 README.md ggml/src/ggml-cuda/kernel.cu tools/run/llama-bench.cpp)"
run_case "stale-guard-overrides-both" true "stale guard" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" SC_BODY="$(body_at "$(ago 200)")" \
  MIN_INTERVAL_HOURS=1000 \
  SC_CMP="$(cmp_with ahead 40 3 README.md docs/x.png ggml/src/ggml-metal/bar.mm)"
run_case "no-relevant-change" false "no-relevant-change" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" SC_BODY="$(body_at "$(ago 100)")" \
  SC_CMP="$(cmp_with ahead 11 4 README.md docs/x.png ggml/src/ggml-cuda/kernel.cu examples/retention/y.cpp)"
run_case "truncated-diff" true "conservative" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" SC_BODY="$(body_at "$(ago 100)")" \
  SC_CMP="$(cmp_with ahead 90 300 README.md)"
run_case "non-linear-history" true "conservative" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" SC_BODY="$(body_at "$(ago 100)")" \
  SC_CMP="$(cmp_with behind 2 1 ggml/src/ggml-hip/a.c)"
run_case "compare-call-fails" true "conservative" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" SC_BODY="$(body_at "$(ago 100)")" SC_CMP_FAIL=1
run_case "unknown-gap-falls-back" true "stale guard" \
  SC_HEAD="$SHA_NEW" SC_THEROCK_LIST="$IDX_SAME_BASE" \
  SC_BODY="<!-- ci-build-state: {\"sha\":\"$SHA_OLD\",\"therock\":\"10.2.0a20261001\"} -->" \
  SC_UPDATED="" SC_CMP="$(cmp_with ahead 5 1 ggml/src/ggml-hip/a.c)"
run_case "pin-therock-skips-index" true "new TheRock SDK base version" \
  SC_HEAD="$SHA_NEW" PIN_THEROCK="10.4.0a20261009" SC_THEROCK_FAIL=1 SC_BODY="$(body_at "$(ago 1)")"
run_case "short-window-sha-compare" false "no-new-version" \
  SC_HEAD="222222277777777777777777777777777777777" SC_BODY='### notes
<!-- ci-build-state: {"sha":"222222211111111111111111111111111111111","therock":"10.2.0a20261001","built_at":"2026-10-08T00:00:00Z"} -->'

echo
echo "== summary =="
if [ -n "${LAST_SUMMARY:-}" ]; then
  echo "--- job summary written by the last passing case ---"
  cat "$LAST_SUMMARY"
  echo "-----------------------------------------------------"
fi
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ -n "$FAILED_CASES" ] && printf 'failed cases:%s\n' "$FAILED_CASES"
[ "$FAIL" -eq 0 ]
