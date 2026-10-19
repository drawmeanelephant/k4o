#!/usr/bin/env bash
# k4o verification script.
#
# Runs locally and in CI (the `verify` job runs it with --check-readme).
# It resolves the repo root from its own location.
# Checks:
#   1. zig build                                          (clean build)
#   2. zig build test                                     (expects success)
#   3. zig build test -Dengine-mode=passthrough           (expects failure: goldbrick engine)
#   4. zig build test -Dengine-mode=noeval                (expects failure: tags never evaluate)
#   5. zig build test -Doptimize=ReleaseSafe              (expects success)
#   6. CLI smoke: the three examples byte-compare, plus error paths
#      (non-zero exit with empty stdout), --help and --version, the
#      --data=FILE form with its empty-value and stray-positional errors,
#      and the --max-output cap tripping on an amplifying render
#   7. static cross-build for x86_64-linux-musl (file(1): "statically linked")
#   8. lint smoke: the clean fixture corpus lints clean, a broken template
#      is rejected with teaching output (rule, construct, why, example),
#      and an unreadable file fails with a diagnostic
#   9. init smoke: teaching files drop into a working dir, a rerun is
#      idempotent, a superseded init file is archived with a reported
#      timestamped path, and a user file is never touched
#
# Logs are written under $KT_VERIFY_DIR (default: a unique directory in
# TMPDIR) and are kept for inspection.
#
# Usage:
#   tools/verify.sh                 verify only (default)
#   tools/verify.sh --check-readme  verify, then assert that README's generated
#                                   results table matches this run (CI uses this)
#   tools/verify.sh --update-readme verify, then rewrite that table in place
#
# CI runs --check-readme, so the README's results table can never quietly
# disagree with a real run. The mutant modes are asserted to FAIL, so a suite
# that stops discriminating breaks the build rather than passing quietly.

set -u

MODE="verify"
case "${1:-}" in
  "") ;;
  --check-readme) MODE="check" ;;
  --update-readme) MODE="update" ;;
  *)
    printf 'usage: %s [--check-readme|--update-readme]\n' "$0" >&2
    exit 2
    ;;
esac

cd "$(dirname "$0")/.." || exit 2
REPO="$PWD"
ZIG="${ZIG:-zig}"
VERIFY_DIR="${KT_VERIFY_DIR:-${TMPDIR:-/tmp}/k4o-verify-$$}"
mkdir -p "$VERIFY_DIR"

pass_count=0
fail_count=0

note() { printf '%s\n' "$*"; }

check_zero() { # desc, log, cmd...
  local desc="$1" log="$2"
  shift 2
  if "$@" >"$log" 2>&1; then
    note "PASS  $desc"
    pass_count=$((pass_count + 1))
  else
    note "FAIL  $desc (expected exit 0)"
    tail -n 15 "$log" | sed 's/^/      | /'
    fail_count=$((fail_count + 1))
  fi
}

check_zero_tests() { # desc, log, cmd... (expects exit 0; a passing run is silent)
  local desc="$1" log="$2"
  shift 2
  if "$@" >"$log" 2>&1; then
    note "PASS  $desc"
    pass_count=$((pass_count + 1))
  else
    note "FAIL  $desc (expected exit 0)"
    tail -n 15 "$log" | sed 's/^/      | /'
    fail_count=$((fail_count + 1))
  fi
}

check_nonzero_tests() { # desc, log, cmd... (expects non-zero AND test failures)
  local desc="$1" log="$2"
  shift 2
  local rc=0
  "$@" >"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    note "FAIL  $desc (expected non-zero exit, got 0)"
    fail_count=$((fail_count + 1))
    return
  fi
  local summary
  summary=$(grep -Eo "[0-9]+ pass, [0-9]+ fail \([0-9]+ total\)" "$log" | tail -1)
  if [ -z "$summary" ]; then
    note "FAIL  $desc (non-zero exit but no test summary — build error?)"
    tail -n 15 "$log" | sed 's/^/      | /'
    fail_count=$((fail_count + 1))
    return
  fi
  # The suite's whole claim is that EVERY test fails against a degraded
  # engine. A non-zero exit is not enough: one test that survives the mutant
  # means it never exercises the engine, and it will quietly weaken the
  # evidence for the other 39. Require zero survivors.
  local survivors
  survivors=$(printf '%s' "$summary" | grep -Eo '^[0-9]+')
  if [ "$survivors" -eq 0 ]; then
    note "PASS  $desc (exit=$rc; $summary)"
    pass_count=$((pass_count + 1))
  else
    note "FAIL  $desc (exit=$rc; $summary — $survivors test(s) passed against the degraded engine)"
    tail -n 15 "$log" | sed 's/^/      | /'
    fail_count=$((fail_count + 1))
  fi
}

check_cli_error() { # desc, logbase, cmd... (expects non-zero exit AND empty stdout)
  local desc="$1" logbase="$2"
  shift 2
  local out rc=0
  out=$("$@" 2>"$logbase.err") || rc=$?
  printf '%s' "$out" >"$logbase.out"
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    note "PASS  $desc (exit=$rc, stdout empty)"
    pass_count=$((pass_count + 1))
  else
    note "FAIL  $desc (exit=$rc, stdout bytes=$(wc -c <"$logbase.out"))"
    tail -n 5 "$logbase.err" | sed 's/^/      | /'
    fail_count=$((fail_count + 1))
  fi
}

check_cli_stderr() { # desc, logbase, needle, cmd... (expects non-zero, empty stdout, needle on stderr)
  local desc="$1" logbase="$2" needle="$3"
  shift 3
  local rc=0
  "$@" >"$logbase.out" 2>"$logbase.err" || rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$logbase.out" ] && grep -qF "$needle" "$logbase.err"; then
    note "PASS  $desc"
    pass_count=$((pass_count + 1))
  else
    note "FAIL  $desc (exit=$rc, stdout bytes=$(wc -c <"$logbase.out"))"
    tail -n 5 "$logbase.err" | sed 's/^/      | /'
    fail_count=$((fail_count + 1))
  fi
}

check_lint_finding() { # desc, logbase, needle, cmd... (expects non-zero exit, needle on stdout, empty stderr)
  local desc="$1" logbase="$2" needle="$3"
  shift 3
  local rc=0
  "$@" >"$logbase.out" 2>"$logbase.err" || rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$logbase.err" ] && grep -qF "$needle" "$logbase.out"; then
    note "PASS  $desc"
    pass_count=$((pass_count + 1))
  else
    note "FAIL  $desc (exit=$rc, expected teaching finding '$needle' on stdout)"
    tail -n 5 "$logbase.out" | sed 's/^/      | /'
    fail_count=$((fail_count + 1))
  fi
}

BIN="$REPO/zig-out/bin/k4o"

check_zero "zig build" "$VERIFY_DIR/01-build.log" "$ZIG" build
check_zero_tests "zig build test (normal: all pass)" "$VERIFY_DIR/02-test.log" \
  "$ZIG" build test
check_nonzero_tests "passthrough mutant fails the suite" "$VERIFY_DIR/03-passthrough.log" \
  "$ZIG" build test -Dengine-mode=passthrough
check_nonzero_tests "noeval mutant fails the suite" "$VERIFY_DIR/04-noeval.log" \
  "$ZIG" build test -Dengine-mode=noeval
check_zero "zig build test -Doptimize=ReleaseSafe (all pass)" "$VERIFY_DIR/05-release-safe.log" \
  "$ZIG" build test -Doptimize=ReleaseSafe

for e in heading list table; do
  check_zero "example '$e' renders byte-exact" "$VERIFY_DIR/06-example-$e.log" \
    bash -c "cd '$REPO' && '$BIN' render 'examples/$e.knap' --data 'examples/$e.json' | cmp -s - 'examples/$e.markdown'"
done

check_cli_error "error path: unknown filter (exit 1, empty stdout)" "$VERIFY_DIR/07-unknown-filter" \
  "$BIN" render "$REPO/fixtures/errors/err-unknown-filter.knap"
check_cli_error "error path: unclosed if block" "$VERIFY_DIR/08-unclosed-if" \
  "$BIN" render "$REPO/fixtures/errors/err-unclosed-if.knap"
check_cli_error "error path: missing data file" "$VERIFY_DIR/09-missing-data" \
  "$BIN" render "$REPO/examples/heading.knap" --data "$REPO/does-not-exist.json"
check_cli_error "error path: malformed JSON data" "$VERIFY_DIR/10-bad-data" \
  "$BIN" render "$REPO/examples/heading.knap" --data "$REPO/fixtures/errors/bad-data.json"
check_cli_error "error path: no arguments" "$VERIFY_DIR/11-no-args" "$BIN"

check_zero "CLI accepts --data=FILE" "$VERIFY_DIR/15-data-equals.log" \
  bash -c "cd '$REPO' && '$BIN' render 'examples/heading.knap' --data='examples/heading.json' | cmp -s - 'examples/heading.markdown'"
check_zero "CLI --format=markdown renders byte-exact" "$VERIFY_DIR/21-markdown.log" \
  bash -c "cd '$REPO' && '$BIN' render 'examples/heading.knap' --data='examples/heading.json' --format=markdown | cmp -s - 'examples/heading.markdown'"
check_zero "CLI --format=oliver renders" "$VERIFY_DIR/25-oliver.log" \
  bash -c "cd '$REPO' && '$BIN' render 'examples/heading.knap' --data='examples/heading.json' --format oliver | cmp -s - 'examples/heading.markdown'"
check_cli_stderr "table output stays empty when the cap trips" "$VERIFY_DIR/27-table-cap" \
  "output exceeded" "$BIN" render "$REPO/examples/table.knap" --data "$REPO/examples/table.json" --max-output=1
check_cli_stderr "CLI rejects unknown formats" "$VERIFY_DIR/23-bad-format" \
  "invalid --format" "$BIN" render "$REPO/examples/heading.knap" --format=html
check_cli_stderr "CLI rejects duplicate formats" "$VERIFY_DIR/24-duplicate-format" \
  "duplicate --format" "$BIN" render "$REPO/examples/heading.knap" --format markdown --format oliver
check_cli_stderr "CLI rejects an empty --data= value" "$VERIFY_DIR/16-data-empty" \
  "missing value for --data" "$BIN" render "$REPO/examples/heading.knap" "--data="
check_cli_stderr "a second positional suggests --data" "$VERIFY_DIR/17-second-positional" \
  "did you mean --data" "$BIN" render "$REPO/examples/heading.knap" "$REPO/examples/heading.json"

# Deep JSON data: structural comparison answers correctly at any depth the
# parser accepts (issue #47), and interpolating a container past Stringify's
# fixed nesting stack is a diagnostic, not a panic (issue #48 — the crash was
# exit 134 with a stack trace, which fails both assertions below).
check_cli_stderr "over-deep interpolation is a diagnostic, not a panic" "$VERIFY_DIR/29-deep-serialize" \
  "100-level limit" "$BIN" render "$REPO/fixtures/errors/err-deep-serialize.knap" --data "$REPO/fixtures/errors/err-deep-serialize.json"

# Nested loops multiply: 200 * 200 iterations of a two-byte body is ~80k
# bytes, so a 100-byte cap must trip immediately with a diagnostic that names
# the loop depth rather than dying on an allocator OOM.
AMP_TPL="$VERIFY_DIR/18-amp.knap"
AMP_JSON="$VERIFY_DIR/18-amp.json"
printf '{%% for x in a %%}{%% for y in a %%}{{ x }}{%% endfor %%}{%% endfor %%}' >"$AMP_TPL"
_amp_items=""
_i=0
while [ "$_i" -lt 200 ]; do
  _amp_items="${_amp_items:+$_amp_items,}$_i"
  _i=$((_i + 1))
done
printf '{"a":[%s]}' "$_amp_items" >"$AMP_JSON"

check_cli_stderr "the output cap fails an amplifying render" "$VERIFY_DIR/18-amp" \
  "output exceeded the 100 byte limit at loop depth 2" "$BIN" render "$AMP_TPL" --data "$AMP_JSON" --max-output=100
check_cli_stderr "an invalid --max-output is rejected" "$VERIFY_DIR/19-bad-max" \
  "not a number" "$BIN" render "$REPO/examples/heading.knap" --data "$REPO/examples/heading.json" --max-output=abc
check_zero "--max-output accepts a suffixed size" "$VERIFY_DIR/20-max-suffix.log" \
  bash -c "'$BIN' render '$REPO/examples/heading.knap' --data='$REPO/examples/heading.json' --max-output=1m | cmp -s - '$REPO/examples/heading.markdown'"

check_zero "CLI renders inline template with -t" "$VERIFY_DIR/34-inline.log" \
  bash -c "test \"\$('$BIN' render -t 'hi {{name}}' --data-json '{\"name\":\"N\"}')\" = 'hi N'"
check_zero "CLI reads the template from stdin" "$VERIFY_DIR/35-stdin-tpl.log" \
  bash -c "printf '{{x}}!' | '$BIN' render --data-json '{\"x\":42}' | grep -q '42!'"
check_zero "CLI --set overrides data" "$VERIFY_DIR/36-set.log" \
  bash -c "test \$('$BIN' render -t '{{v}}' --data-json '{\"v\":1}' --set v=9) = 9"
check_zero "CLI -o writes output to a file" "$VERIFY_DIR/37-outfile.log" \
  bash -c "cd '$VERIFY_DIR' && '$BIN' render -t 'x{{n}}' --set n=1 -o out.md && grep -q x1 out.md"
check_zero "validate accepts a clean template" "$VERIFY_DIR/38-validate.log" \
  bash -c "'$BIN' validate -t '{{ ok }}'"
check_cli_error "validate rejects a broken template" "$VERIFY_DIR/39-validate-bad" \
  bash -c "'$BIN' validate -t '{{ bad'"
check_zero "help lists filters" "$VERIFY_DIR/40-help.log" \
  bash -c "'$BIN' help filters | grep -q ' bold'"
check_zero "--help exits 0" "$VERIFY_DIR/12-help.log" "$BIN" --help
check_zero "--version exits 0" "$VERIFY_DIR/13-version.log" "$BIN" --version

# Lint: the whole clean corpus (templates that render are templates that
# parse) plus the teaching path on a broken template.
check_zero "lint: the fixture corpus is clean" "$VERIFY_DIR/30-lint-corpus.log" \
  "$BIN" lint "$REPO"/fixtures/*.knap "$REPO"/examples/*.knap
check_lint_finding "lint: a broken template is rejected with teaching output" "$VERIFY_DIR/31-lint-broken" \
  "unclosed-if" "$BIN" lint "$REPO/fixtures/errors/err-unclosed-if.knap"
check_lint_finding "lint: an unknown filter teaches the registry" "$VERIFY_DIR/32-lint-registry" \
  "unknown-filter" "$BIN" lint "$REPO/fixtures/errors/err-unknown-filter.knap"
# An unreadable file reports on stderr and still gets the stdout summary,
# because lint reports on every file it could open before failing overall.
LINT_OUT="$VERIFY_DIR/33-lint-missing.out"
LINT_ERR="$VERIFY_DIR/33-lint-missing.err"
rc=0
"$BIN" lint "$REPO/does-not-exist.knap" >"$LINT_OUT" 2>"$LINT_ERR" || rc=$?
if [ "$rc" -ne 0 ] && grep -qF "cannot read template file" "$LINT_ERR" && grep -qF "1 file(s) unreadable" "$LINT_OUT"; then
  note "PASS  lint: an unreadable file fails with a diagnostic"
  pass_count=$((pass_count + 1))
else
  note "FAIL  lint: an unreadable file fails with a diagnostic (exit=$rc)"
  tail -n 5 "$LINT_ERR" | sed 's/^/      | /'
  fail_count=$((fail_count + 1))
fi

# init: the whole lifecycle — create, idempotent rerun, supersede-with-archive,
# and the never-touch-user-files rule — in throwaway sandboxes.
INIT_FRESH="$VERIFY_DIR/34-init-fresh"
INIT_SUPER="$VERIFY_DIR/35-init-supersede"
rm -rf "$INIT_FRESH" "$INIT_SUPER" && mkdir -p "$INIT_FRESH" "$INIT_SUPER"
check_zero "init: teaching files drop into a working dir" "$VERIFY_DIR/34-init-fresh.log" \
  bash -c "cd '$INIT_FRESH' && '$BIN' init && test -f knap-tour.md && test -f knap-templates.md && test -f knap-examples.md && test -f knap-gotchas.md"
check_zero "init: a rerun is idempotent" "$VERIFY_DIR/34-init-rerun.log" \
  bash -c "cd '$INIT_FRESH' && '$BIN' init | grep -q '0 created, 4 untouched, 0 archived'"
check_zero "init: supersede archives and user files are untouched" "$VERIFY_DIR/35-init-supersede.log" \
  bash -c "cd '$INIT_SUPER' && '$BIN' init >/dev/null && printf 'random user content\n' > knap-gotchas.md && printf '<!-- k4o init knap-tour v0 -->\n# old tour\n' > knap-tour.md && '$BIN' init > init.out && grep -q 'archived to k4o-archive/' init.out && grep -q 'knap-tour v5' knap-tour.md && cmp -s 'k4o-archive'/*/knap-tour.md <(printf '<!-- k4o init knap-tour v0 -->\n# old tour\n') && cmp -s knap-gotchas.md <(printf 'random user content\n')"

check_zero "static x86_64-linux-musl build is statically linked" "$VERIFY_DIR/14-static.log" \
  bash -c "'$ZIG' build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl --prefix '$VERIFY_DIR/static' && file '$VERIFY_DIR/static/bin/k4o' | grep -q 'statically linked'"

# ---- README results table -------------------------------------------------
# The three engine modes yield a short results table. It is generated from this
# run and committed, then re-asserted by CI, so it cannot silently rot.
#
# A *passing* `zig build test` prints no summary (Zig is quiet on success), so
# the normal row's counts are derived from the mutant logs, which do report
# "(N total)" for the same suite.
TABLE_START='<!-- verify-table:start -->'
TABLE_END='<!-- verify-table:end -->'

summary_counts() { # log -> "<passed> <failed> <total>" (empty if none printed)
  local log="$1" line p f t
  line=$(grep -Eo "[0-9]+ pass, [0-9]+ fail \([0-9]+ total\)" "$log" | tail -1)
  [ -n "$line" ] || return 0
  p=${line%% pass,*}
  f=${line#* pass, }
  f=${f%% fail*}
  t=${line#*\(}
  t=${t%% *}
  printf '%s %s %s' "$p" "$f" "$t"
}

generate_table() { # -> prints the table body for this run
  local pt_p pt_f md_p md_f total
  # shellcheck disable=SC2046 # word splitting is the point: set -- takes fields
  set -- $(summary_counts "$VERIFY_DIR/03-passthrough.log")
  pt_p=${1:-?}; pt_f=${2:-?}; total=${3:-?}
  # shellcheck disable=SC2046
  set -- $(summary_counts "$VERIFY_DIR/04-noeval.log")
  md_p=${1:-?}; md_f=${2:-?}
  printf '| Mode | Result |\n'
  printf '| --- | --- |\n'
  # shellcheck disable=SC2016 # backticks are literal Markdown, not command sub
  printf '| `normal` | %s passed, %s failed |\n' "$total" "0"
  # shellcheck disable=SC2016
  printf '| `passthrough` | %s passed, %s failed |\n' "$pt_p" "$pt_f"
  # shellcheck disable=SC2016
  printf '| `noeval` | %s passed, %s failed |\n' "$md_p" "$md_f"
}

sync_readme() { # honour $MODE: check | update
  local tmp gen
  if [ "$fail_count" -ne 0 ]; then
    note "NOTE  skipping README table sync (verification already failed)"
    return
  fi
  if ! grep -qF "$TABLE_START" README.md || ! grep -qF "$TABLE_END" README.md; then
    note "FAIL  README.md is missing the verify-table markers"
    fail_count=$((fail_count + 1))
    return
  fi
  tmp=$(mktemp) || return
  gen=$(mktemp) || return
  generate_table >"$gen"
  # The table is passed via a file, not -v: BSD awk (macOS) refuses -v values
  # containing newlines, which would silently produce an empty README.
  if awk -v start="$TABLE_START" -v end="$TABLE_END" -v genfile="$gen" '
    function emit(   line) {
      while ((getline line < genfile) > 0) print line
      close(genfile)
    }
    $0 == start { print; emit(); skip = 1; next }
    $0 == end   { skip = 0; print; next }
    !skip       { print }
  ' README.md >"$tmp" && [ -s "$tmp" ]; then
    :
  else
    note "FAIL  could not regenerate the README table"
    fail_count=$((fail_count + 1))
    rm -f "$tmp" "$gen"
    return
  fi
  if cmp -s "$tmp" README.md; then
    note "PASS  README results table matches this run"
    pass_count=$((pass_count + 1))
  elif [ "$MODE" = update ]; then
    cp "$tmp" README.md
    note "NOTE  README results table rewritten from this run"
  else
    note "FAIL  README results table is stale (re-run with --update-readme)"
    diff -u README.md "$tmp" | tail -n 12 | sed 's/^/      | /'
    fail_count=$((fail_count + 1))
  fi
  rm -f "$tmp" "$gen"
}

if [ "$MODE" != verify ]; then
  sync_readme
fi

note "-------------------------------------------"
note "k4o verify: $pass_count passed, $fail_count failed"
note "logs kept under: $VERIFY_DIR"
if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
exit 0
