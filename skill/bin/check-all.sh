#!/usr/bin/env bash
# check-all.sh -- one command that answers "is this installation sound?"
#
#   bash check-all.sh             static checks, Codex is not called (fast)
#   bash check-all.sh --live      plus one real call (ping route, ~20s)
#   bash check-all.sh --scan-only just the dangerous-construct scan
#
# --scan-only exists so the test suite can exercise this scan without calling
# the whole script: check-all runs the suites, so a suite calling check-all
# would re-enter itself without end.
#
# Run it after any edit, after a Codex upgrade, and whenever you are unsure of
# the state of things.

set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL=$(cd "$BIN/.." && pwd)
# shellcheck source=compat.sh
. "$BIN/compat.sh"

FAIL=0
step() { printf '\n== %s ==\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

if [ "${1-}" = --scan-only ]; then
  SCAN_ONLY=1
else
  SCAN_ONLY=0
  step "Platform"
  ok "$(compat_report)"

  step "Files present"
fi
if [ "$SCAN_ONLY" = 0 ]; then
for f in SKILL.md bin/routes.conf bin/compat.sh bin/codex-run.sh bin/codex-snapshot.sh \
         bin/codex-consensus.sh bin/gen-routes-table.sh bin/test-routes.sh \
         bin/test-snapshot.sh bin/agents-anchor.txt bin/expected-codex-version.txt \
         reference/prompts.md reference/review-schema.json \
         reference/models-and-limits.md reference/imagegen.md; do
  [ -s "$SKILL/$f" ] && ok "$f" || no "$f -- missing or empty"
done

step "Shell syntax"
for f in "$BIN"/*.sh; do
  bash -n "$f" 2>/dev/null && ok "$(basename "$f")" || no "$(basename "$f") -- syntax"
done
fi   # end of the section skipped by --scan-only

step "Dangerous constructs"
# This file is excluded from its own scan: it contains the search patterns as
# TEXT and would otherwise match itself.
# An ARRAY, not a newline-joined string expanded unquoted. The earlier form was
# word-split on spaces, so with a path like "C:/Claude Skills/..." grep received
# fragments, every file was missing, and `wc -l` counted 0 -- the three checks
# below printed ok while reading nothing. Verified: a planted `eval` went
# unreported.
SCAN=()
for f in "$BIN"/*.sh; do
  case $f in */check-all.sh) continue ;; esac
  SCAN+=("$f")
done
[ ${#SCAN[@]} -gt 0 ] || no "no scripts found to scan -- check the installation"
# grep exit 1 is "clean", 0 is "found it", anything above 1 is a BROKEN CHECK
# and must be reported as a failure rather than counted as clean.
scan_none() {                     # scan_none <mode> <pattern> <ok msg> <fail msg>
  local mode=$1 pat=$2 okmsg=$3 badmsg=$4 hits rc
  hits=$(grep -l "$mode" -- "$pat" "${SCAN[@]}" 2>/dev/null); rc=$?
  case $rc in
    1) ok "$okmsg" ;;
    0) no "$badmsg: $(printf '%s' "$hits" | tr '\n' ' ')" ;;
    *) no "$badmsg -- the check itself failed (grep returned $rc)" ;;
  esac
}
# eval AS A COMMAND: at line start or after a separator. A '^[^#]*eval' form is
# bypassed by  x='#'; eval "$p" , and a bare \beval\b matches the word in
# comments that explain why eval is avoided.
scan_none -E '(^|[;&|{(]|then |else |do )[[:space:]]*eval[[:space:]]' \
  "eval is never called" "eval called in"
scan_none -F "printf '-" \
  "no printf with a dash-leading format" "dash-leading printf format in"
# A variable inside a sed EXPRESSION (a line carrying an s/ or s| command).
# GNU sed's s///e flag executes the substitution result as a shell command.
scan_none -E 'sed[^|;]*"[^"]*s[/|][^"]*\$' \
  "no variables interpolated into a sed expression" \
  "variable interpolated into a sed expression in"

if [ "$SCAN_ONLY" = 1 ]; then
  [ "$FAIL" -eq 0 ] && exit 0
  printf '\n%d construct failure(s).\n' "$FAIL"; exit 1
fi

step "Calls in flight (editing bin/*.sh during a call breaks it)"
if [ -f "$SKILL/var/calls.jsonl" ] && command -v node >/dev/null 2>&1; then
  read -r fresh old < <(node -e '
    const fs=require("fs");
    const e=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(JSON.parse);
    const s=e.filter(x=>x.event==="started"), d=e.filter(x=>x.event==="finished");
    const o=s.filter(x=>!d.some(y=>y.call_id===x.call_id));
    // A call cannot outlive its own timeout, so anything older is a historical
    // abort, not an active run.
    const now=Date.now();
    const f=o.filter(x=>(now-Date.parse(x.ts))/1000 < (Number(x.timeout)||600)+120).length;
    console.log(f+" "+(o.length-f));
  ' "$SKILL/var/calls.jsonl" 2>/dev/null)
  if [ "${fresh:-0}" -gt 0 ]; then
    printf '  !    A CALL IS RUNNING (%s unfinished) -- do not edit bin/*.sh until it ends\n' "$fresh"
  else ok "no active calls -- editing is safe"; fi
  [ "${old:-0}" -gt 0 ] && printf '  .    aborted earlier: %s (historical, harmless)\n' "$old"
else ok "no log yet (no calls have been made)"; fi

step "Log integrity"
if [ -f "$SKILL/var/calls.jsonl" ] && command -v node >/dev/null 2>&1; then
  node -e '
    const fs=require("fs");
    const ls=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
    let bad=0; for(const l of ls){ try{JSON.parse(l)}catch(e){bad++} }
    process.exit(bad?1:0);
  ' "$SKILL/var/calls.jsonl" >/dev/null 2>&1 && ok "every line is valid JSON" \
    || no "the log contains torn lines"
else ok "nothing to check"; fi

step "Registry and generated table"
bash "$BIN/gen-routes-table.sh" --check >/dev/null 2>&1 \
  && ok "route table matches the registry" \
  || no "table has drifted -- run: bash bin/gen-routes-table.sh --write"

step "Regression suites"
# RECURSION GUARD. check-all runs the suites, and a suite has a case that runs
# check-all -- without this marker the two call each other forever, each level
# creating a new temp tree. That is not hypothetical: an interrupted run left a
# tree of processes that kept multiplying for three hours before anyone noticed,
# because killing the parent does not kill the children.
#
# --scan-only exists for the same reason and is the right way for a test to
# reach this file; the marker is the belt to that pair of braces, and it holds
# no matter how check-all is invoked.
if [ -n "${CODEX_BRIDGE_IN_SUITE:-}" ]; then
  printf '  .    skipped: already running inside a suite (recursion guard)\n'
  SKIP_SUITES=1
else
  SKIP_SUITES=0
fi
# The EXIT CODE is checked, not a substring of the last line: a suite that dies
# halfway prints no summary at all, and a broken suite could print anything.
run_suite() {
  local o rc last
  # The marker is exported into the suite, so anything the suite starts -- and
  # anything that starts -- inherits it.
  o=$(CODEX_BRIDGE_IN_SUITE=1 bash "$1" 2>&1); rc=$?
  last=$(printf '%s\n' "$o" | tail -1)
  if [ "$rc" -eq 0 ] && printf '%s\n' "$last" | grep -q 'failed 0'; then
    ok "$2: $last"
  else
    no "$2: rc=$rc, last line: ${last:-<empty>}"
    printf '%s\n' "$o" | grep -E '^  FAIL' | head -5 | sed 's/^/      /'
  fi
}
if [ "$SKIP_SUITES" = 0 ]; then
run_suite "$BIN/test-routes.sh"   "routes"
run_suite "$BIN/test-snapshot.sh" "snapshot"
fi

step "Codex environment"
if command -v codex >/dev/null 2>&1; then
  V=$(codex --version 2>/dev/null)
  E=$(cat "$BIN/expected-codex-version.txt" 2>/dev/null || printf '')
  if [ -z "$E" ]; then ok "version $V (no pin recorded)"
  elif [ "$V" = "$E" ]; then ok "version matches the verified one: $V"
  # A mismatch is a FAILURE, not a note. The closing line claims the kit is
  # sound -- that its premises hold. On a different CLI version nothing confirms
  # them, and flag behaviour is what the whole kit stands on. This used to print
  # a note without touching FAIL, so after a Codex upgrade check-all still said
  # "nothing failed" and exited 0.
  else no "version $V, but the facts here were verified on $E -- re-run both suites, re-check the CLI help, then update bin/expected-codex-version.txt"; fi
  codex login status 2>&1 | grep -qi 'logged in' && ok "logged in" || no "not logged in -- run: codex login"
  ANCHOR=$(cat "$BIN/agents-anchor.txt" 2>/dev/null || printf 'Look for what breaks')
  # Codex honours CODEX_HOME and so does install.sh; looking only in ~/.codex
  # reported a correct install as broken whenever one was set. A relative value
  # is refused, not resolved: it would name a different directory for every
  # process, and this check would pass or fail on the caller's cwd.
  CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
  compat_is_absolute "$CODEX_DIR" \
    || { no "CODEX_HOME must be an absolute path (got '$CODEX_DIR')"; CODEX_DIR=''; }
  if [ -n "$CODEX_DIR" ]; then
    grep -qF -- "$ANCHOR" "$CODEX_DIR/AGENTS.md" 2>/dev/null \
      && ok "reviewer instruction present in $CODEX_DIR/AGENTS.md" \
      || no "$CODEX_DIR/AGENTS.md missing or lacks the reviewer instruction -- run install.sh"
    [ -f "$CODEX_DIR/claude-safe.config.toml" ] \
      && ok "claude-safe profile present" || no "missing $CODEX_DIR/claude-safe.config.toml -- run install.sh"
    grep -q '^\[agents\]' "$CODEX_DIR/config.toml" 2>/dev/null \
      && ok "[agents] present (fanout route usable)" \
      || printf '  .    no [agents] in %s/config.toml -- the fanout route will not fan out\n' "$CODEX_DIR"
  fi
else no "codex is not in PATH -- there is no bridge"; fi

if [ "${1-}" = --live ]; then
  step "Live call (ping route)"
  TMP=$(compat_mktemp_dir); printf 'Reply with one word: alive.\n' > "$TMP/p.txt"
  printf 'route=ping\ndir=%s\nout_dir=%s\nprompt_file=%s/p.txt\nsubject=check-all live probe\nephemeral=yes\n' \
    "$SKILL/reference" "$TMP" "$TMP" > "$TMP/r.conf"
  OUT=$(bash "$BIN/codex-run.sh" "$TMP/r.conf" 2>/dev/null); rc=$?
  if [ $rc -eq 0 ] && [ -f "$OUT" ]; then
    ok "call succeeded, verdict: $(head -c 60 "$OUT")"
    [ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] && ok "stdout is exactly one line (the verdict path)" \
      || no "stdout contract violated"
  else no "live call produced no verdict (rc=$rc)"; fi
  rm -rf "$TMP"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then printf 'RESULT: installation is sound, no failures.\n'; exit 0
else printf 'RESULT: %d FAILURES -- resolve before using.\n' "$FAIL"; exit 1; fi
