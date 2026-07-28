#!/usr/bin/env bash
# test-routes.sh -- golden tests for argv assembly, request validation and the
# route registry.
#
# Run:  bash test-routes.sh
# Codex is never called: everything goes through CODEX_RUN_DRYRUN=1 (exit 9).
#
# Half of what used to break this skill was not the hand-assembled command line.
# It was UNVERIFIED assumptions about how the tools behave. Only tests catch
# those.

set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN="$BIN/codex-run.sh"
REG="$BIN/routes.conf"
DRYRC=9                              # a dry run exits 9, not 0: the contract
                                     # "0 means a verdict was received" must not
                                     # break because a variable leaked into the
                                     # environment

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
# A case that cannot be constructed here is NOT a pass. Counting it as one is
# how a suite comes to look green on a platform where it proved nothing.
skip() { SKIP=$((SKIP+1)); printf '  skip %s\n       %s\n' "$1" "$2"; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/work" "$T/out" "$T/assets"
printf 'find what breaks\n' > "$T/p.txt"
printf '{"type":"object"}\n' > "$T/schema.json"
printf 'PNG\n'              > "$T/a.png"
printf 'PNG\n'              > "$T/b.png"
UUID=019fa61d-29e9-7340-8205-49fc797738de
SHA=46e6cee8b17b3f26c94fb8327c252e11561f8e0f

req() { local f=$1; shift; : > "$f"; printf '%s\n' "$@" >> "$f"; }
dry() { CODEX_RUN_DRYRUN=1 bash "${RUNX:-$RUN}" "$1" 2>/dev/null; }
# rc is captured on a SEPARATE line: `[ $? -eq N ] && ok || bad "rc=$?"` would
# print the exit code of the test itself, not of the command.
rc_dry() { CODEX_RUN_DRYRUN=1 bash "${RUNX:-$RUN}" "$1" >/dev/null 2>&1; printf '%s' $?; }
expect_rc() { local want=$1 name=$2 got; got=$(rc_dry "$T/r.conf"); \
  [ "$got" = "$want" ] && ok "$name" || bad "$name" "expected rc=$want, got rc=$got"; }

has()  { printf '%s\n' "$1" | grep -qxF -- "$2"; }
pair() { printf '%s\n' "$1" | grep -A1 -xF -- "$2" | tail -1 | grep -qxF -- "$3"; }

echo "== 1. Explicit expectations for key routes (NOT derived from the registry) =="
# Anti-tautology: if `review` ever became workspace-write, a test that reads its
# expectation from the same registry would call that correct.
check_explicit() {              # <route> <model> <effort> <sandbox> <ignore|base> <profile>
  local r=$1 m=$2 e=$3 s=$4 c=$5 p=$6 lines err='' o
  lines=(route="$r" dir="$T/work" out_dir="$T/out" subject="explicit expectation")
  case $r in review-builtin) lines+=(commit=$SHA) ;; *) lines+=(prompt_file=$T/p.txt) ;; esac
  case $r in image*) lines+=(image=$T/a.png confirm_background=yes) ;; esac
  case $r in *-critical|fanout) lines+=(confirm_background=yes) ;; esac
  req "$T/r.conf" "${lines[@]}"; o=$(dry "$T/r.conf")
  pair "$o" -m "$m" || err="$err model!=$m;"
  has "$o" "model_reasoning_effort=\"$e\"" || err="$err effort!=$e;"
  pair "$o" -s "$s" || err="$err sandbox!=$s;"
  if [ "$c" = ignore ]; then has "$o" --ignore-user-config || err="$err no --ignore-user-config;"
  else has "$o" --ignore-user-config && err="$err stray --ignore-user-config;"; fi
  if [ "$p" = none ]; then has "$o" -p && err="$err stray -p;"
  else pair "$o" -p "$p" || err="$err profile!=$p;"; fi
  [ -z "$err" ] && ok "$r" || bad "$r" "$err"
}
check_explicit ping             gpt-5.6-luna  low    read-only       ignore none
check_explicit review           gpt-5.6-terra high   read-only       ignore none
check_explicit review-builtin   gpt-5.6-terra high   read-only       ignore none
check_explicit review-critical  gpt-5.6-sol   xhigh  read-only       ignore none
check_explicit plan-critical    gpt-5.6-sol   max    read-only       ignore none
check_explicit fanout           gpt-5.6-sol   ultra  read-only       base   none
check_explicit image            gpt-5.6-sol   high   workspace-write base   claude-safe
check_explicit image-draft      gpt-5.6-terra medium workspace-write base   claude-safe

echo
echo "== 2. Every registry route assembles, and none gains extra privilege =="
while IFS= read -r route; do
  m=''; e=''; c=''; p=''; s=''; fo=''; bg=''; in=0
  while IFS= read -r raw; do
    l=${raw%$'\r'}
    case $l in ''|'#'*) [ $in -eq 1 ] && break; continue ;; esac
    k=${l%%:*}; v=${l#*: }
    [ "$k" = route ] && { [ "$v" = "$route" ] && in=1 || in=0; continue; }
    [ $in -eq 1 ] || continue
    case $k in model) m=$v;; effort) e=$v;; config) c=$v;; profile) p=$v;;
                sandbox) s=$v;; form) fo=$v;; background) bg=$v;; esac
  done < "$REG"
  lines=(route="$route" dir="$T/work" out_dir="$T/out" subject="route")
  [ "$fo" = review ] && lines+=(commit=$SHA) || lines+=(prompt_file=$T/p.txt)
  [ "$bg" = yes ] && lines+=(confirm_background=yes)
  case $route in image*) lines+=(image=$T/a.png) ;; esac
  req "$T/r.conf" "${lines[@]}"; o=$(dry "$T/r.conf")
  err=''
  pair "$o" -s "$s" || err="$err sandbox!=$s;"
  # pair, not has: has takes two arguments, so a third was silently ignored and
  # the check degenerated into "is there a -s at all", which is always true.
  pair "$o" -s danger-full-access && err="$err DANGER-FULL-ACCESS;"
  if [ "$fo" = review ]; then has "$o" review || err="$err no review;"
                              has "$o" - && err="$err review took a prompt;"
  else has "$o" - || err="$err no '-';"; fi
  [ -z "$err" ] && ok "$route" || bad "$route" "$err"
done < <(grep '^route: ' "$REG" | sed 's/^route: //')

echo
echo "== 3. Flag order and flag form =="
req "$T/r.conf" route=review-builtin dir="$T/work" out_dir="$T/out" subject=order commit=$SHA
o=$(dry "$T/r.conf")
si=$(printf '%s\n' "$o" | grep -nxF -- -s | head -1 | cut -d: -f1)
ri=$(printf '%s\n' "$o" | grep -nxF review | head -1 | cut -d: -f1)
{ [ -n "$si" ] && [ -n "$ri" ] && [ "$si" -lt "$ri" ]; } \
  && ok "common flags come before the subcommand" || bad "flag order" "-s=${si:-none} review=${ri:-none}"

req "$T/r.conf" route=review-builtin dir="$T/work" out_dir="$T/out" subject=branch base=main
o=$(dry "$T/r.conf")
{ pair "$o" review --base && pair "$o" --base main && ! has "$o" --commit; } \
  && ok "review --base main" || bad "review --base" "argv: $(printf '%s' "$o" | tr '\n' ' ')"

req "$T/r.conf" route=review-critical dir="$T/work" out_dir="$T/out" subject=resume \
    prompt_file="$T/p.txt" session_id=$UUID confirm_background=yes
o=$(dry "$T/r.conf")
err=''
has "$o" --ignore-user-config || err="$err no --ignore-user-config;"
pair "$o" -s read-only        || err="$err no -s read-only;"
pair "$o" resume "$UUID"      || err="$err no resume <id>;"
[ -z "$err" ] && ok "resume gets the full flag set" || bad "resume" "$err"

req "$T/r.conf" route=image dir="$T/assets" out_dir="$T/out" subject=picture \
    prompt_file="$T/p.txt" image="$T/a.png" image="$T/b.png" confirm_background=yes
o=$(dry "$T/r.conf")
n=$(printf '%s\n' "$o" | grep -c '^--image=')
{ [ "$n" -eq 2 ] && has "$o" "--image=$T/a.png" && has "$o" "--image=$T/b.png"; } \
  && ok "two --image= in the '=' form" || bad "--image=" "found $n"

echo
echo "== 4. Request validation =="
req "$T/r.conf" route=nosuchroute dir="$T/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt"
expect_rc 2 "unknown route"
req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt" bogus=field
expect_rc 2 "unknown field"
req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" prompt_file="$T/p.txt"
expect_rc 2 "no subject"
req "$T/r.conf" route=ping dir="$T/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt" commit=$SHA
expect_rc 2 "field outside allows"
req "$T/r.conf" route=review-builtin dir="$T/work" out_dir="$T/out" subject=x commit=$SHA prompt_file="$T/p.txt"
expect_rc 2 "prompt together with review"
req "$T/r.conf" route=review-builtin dir="$T/work" out_dir="$T/out" subject=x commit=$SHA base=main
expect_rc 2 "commit and base together"
req "$T/r.conf" route=review-builtin dir="$T/work" out_dir="$T/out" subject=x
expect_rc 2 "review-builtin with no subject to review"
req "$T/r.conf" route=plan-critical dir="$T/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt"
expect_rc 3 "background route without confirmation"

# session_id: --last would become a CLI OPTION and continue somebody else's session
for badsid in --last "$UUID-tail" "not-a-uuid" ""; do
  req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" subject=x \
      prompt_file="$T/p.txt" session_id="$badsid"
  got=$(rc_dry "$T/r.conf")
  if [ -z "$badsid" ]; then
    [ "$got" = "$DRYRC" ] && ok "empty session_id is ignored" || bad "empty session_id" "rc=$got"
  else
    [ "$got" = 2 ] && ok "session_id='$badsid' refused" || bad "session_id='$badsid'" "rc=$got"
  fi
done

# commit: HEAD, a branch, an abbreviated SHA -- a moving or wrong target
for badc in HEAD main 46e6cee "${SHA}00"; do
  req "$T/r.conf" route=review-builtin dir="$T/work" out_dir="$T/out" subject=x commit="$badc"
  expect_rc 2 "commit='$badc' refused"
done

# out_dir inside dir: -o writes regardless of the sandbox
mkdir -p "$T/work/inside"
req "$T/r.conf" route=review dir="$T/work" out_dir="$T/work/inside" subject=x prompt_file="$T/p.txt"
expect_rc 2 "out_dir inside dir refused"

# a project-level Codex config is a stop, not a warning
mkdir -p "$T/work/.codex"; printf 'x=1\n' > "$T/work/.codex/config.toml"
req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt"
expect_rc 2 "project .codex/config.toml stops the call"
rm -rf "$T/work/.codex"

# ...but ~/.codex/config.toml is the USER's, not a project's. Without the walk
# boundary the gate fired on every directory inside $HOME (caught by a live run,
# not by tests: mktemp puts everything in /tmp, outside $HOME).
HT="$HOME/.codex-bridge-test-$$"; mkdir -p "$HT/work"
req "$T/r.conf" route=review dir="$HT/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt"
got=$(rc_dry "$T/r.conf")
[ "$got" = "$DRYRC" ] && ok "a directory inside \$HOME is not a project with a config" \
  || bad "false positive on ~/.codex" "rc=$got"
rm -rf "$HT"

echo
echo "== 5. Registry validation (on a COPY; production files untouched) =="
C="$T/bincopy"; mkdir -p "$C"; cp "$BIN/codex-run.sh" "$BIN/compat.sh" "$C/"
reg_case() {                       # <awk program> <expected rc> <name>
  awk "$1" "$REG" > "$C/routes.conf"
  req "$T/r.conf" route=ping dir="$T/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt"
  RUNX="$C/codex-run.sh" got=$(RUNX="$C/codex-run.sh" rc_dry "$T/r.conf")
  [ "$got" = "$2" ] && ok "$3" || bad "$3" "expected rc=$2, got rc=$got"
}
reg_case '{print}'                                             "$DRYRC" "an intact registry passes"
reg_case '/^route: ping$/{p=1} p&&/^sandbox: /{next} /^$/{p=0} {print}' 2 "route with no sandbox refused"
reg_case '/^route: ping$/{p=1} p&&/^allows: /{next} /^$/{p=0} {print}'  2 "route with no allows refused"
reg_case '/^route: ping$/{p=1} p&&/^config: /{sub(/ignore/,"ignroe")} /^$/{p=0} {print}' 2 "typo in config refused"
reg_case '/^route: ping$/{p=1} p&&/^sandbox: /{sub(/read-only/,"danger-full-access")} /^$/{p=0} {print}' 2 "danger-full-access refused"
reg_case '/^route: ping$/{p=1} p&&/^effort: /{sub(/low/,"turbo")} /^$/{p=0} {print}' 2 "nonexistent effort refused"
reg_case '/^route: ping$/{p=1} p&&/^timeout: /{sub(/120/,"soon")} /^$/{p=0} {print}' 2 "non-numeric timeout refused"
reg_case '/^route: ping$/{p=1} p&&/^model: /{sub(/gpt-5.6-luna/,"gpt-4")} /^$/{p=0} {print}' 2 "model outside the family refused"
reg_case '{print} /^route: ping$/{print "bogus: field"}'       2 "unknown registry field refused"
# workspace-write without the base config: the sandbox silently degrades
awk '/^route: image$/{p=1} p&&/^config: /{sub(/base/,"ignore")} /^$/{p=0} {print}' "$REG" > "$C/routes.conf"
req "$T/r.conf" route=image dir="$T/assets" out_dir="$T/out" subject=x prompt_file="$T/p.txt" \
    image="$T/a.png" confirm_background=yes
got=$(RUNX="$C/codex-run.sh" rc_dry "$T/r.conf")
[ "$got" = 2 ] && ok "workspace-write with config=ignore refused" || bad "workspace-write/ignore" "rc=$got"
unset RUNX

echo
echo "== 6. Injection: dangerous values arrive as data, never as code =="
rm -f "$T/TRACE"
EVIL='$(touch '"$T"'/TRACE)`touch '"$T"'/TRACE`'
mkdir -p "$T/work/$EVIL" 2>/dev/null
req "$T/r.conf" route=review dir="$T/work/$EVIL" out_dir="$T/out" subject="$EVIL" prompt_file="$T/p.txt"
o=$(dry "$T/r.conf")
if [ -f "$T/TRACE" ]; then bad "path with \$() and \`\`" "FILE WAS CREATED"
elif pair "$o" -C "$T/work/$EVIL"; then ok "path with \$() and \`\` arrived literally"
else bad "path with \$() and \`\`" "argv does not contain the path"; fi

# A dry run never opens the prompt file, so "no TRACE2 was created" would be
# true even if the real path executed the prompt -- the assertion has to be
# about what the dry run CAN show: that the prompt is wired to stdin and its
# text never becomes an argument. The real path is exercised in section 7d.
printf 'text\nPROMPT\n$(touch %s/TRACE2) `id`\n' "$T" > "$T/evil.txt"
req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" subject=injection prompt_file="$T/evil.txt"
o=$(dry "$T/r.conf")
if ! has "$o" "STDIN<$T/evil.txt"; then bad "prompt wiring" "stdin points at the wrong file"
elif printf '%s\n' "$o" | grep -q 'touch\|`id`'; then bad "prompt wiring" "prompt text leaked into argv"
else ok "the prompt reaches stdin and never becomes an argument"; fi

Q="$T/work/it's-a-quote"; mkdir -p "$Q" 2>/dev/null
req "$T/r.conf" route=review dir="$Q" out_dir="$T/out" subject="single'quote" prompt_file="$T/p.txt"
o=$(dry "$T/r.conf")
pair "$o" -C "$Q" && ok "path with a single quote arrived literally" \
                  || bad "path with a single quote" "argv does not contain the path"

echo
echo "== 7. Log: JSON stays valid on hostile values (through the real log_event) =="
# The earlier test copied json_escape and never touched production code, so it
# stayed green while the log itself was invalid.
LOG="$BIN/../var/calls.jsonl"
before=0; [ -f "$LOG" ] && before=$(wc -l < "$LOG")
for subj in '--' '-' '1-2' 'quote " backslash \ tab	end' '0'; do
  req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" subject="$subj" prompt_file="$T/p.txt"
  CODEX_RUN_DRYRUN=1 bash "$RUN" "$T/r.conf" >/dev/null 2>&1     # a dry run writes no log
done
# Write a log line with the REAL function: pull it out of the runner without calling Codex.
( CALL_ID=TEST; LOG_DIR="$T"; LOG="$T/j.jsonl"
  # shellcheck disable=SC1090
  # One -e per range, not two ranges joined by ';'. BSD sed (macOS) rejects the
  # joined form, the extraction produced nothing, and the sourced file defined no
  # functions -- "log_event: command not found", five times, and a red suite.
  # shellcheck disable=SC1090
  source <(sed -n -e '/^json_escape()/,/^}/p' -e '/^log_event()/,/^}/p' "$RUN")
  for s in '--' '-' '1-2' '0' 'quote " backslash \ tab	end'; do log_event t subject "$s" n 5; done )
if command -v node >/dev/null 2>&1 && [ -f "$T/j.jsonl" ]; then
  node -e '
    const fs=require("fs");
    const ls=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
    let bad=0; for(const l of ls){ try{JSON.parse(l)}catch(e){bad++; console.log("INVALID: "+l)} }
    process.exit(bad?1:0);
  ' "$T/j.jsonl" && ok "every log line is valid JSON" || bad "log" "some lines are invalid"
else bad "log" "node unavailable or the file was not created"; fi
after=0; [ -f "$LOG" ] && after=$(wc -l < "$LOG")
[ "$before" = "$after" ] && ok "a dry run writes nothing to the log" || bad "dry run wrote to the log" "$before -> $after"

echo
echo "== 7a. Consensus: findings matched by meaning, not by line proximity =="
CONS="$BIN/codex-consensus.sh"
mkv() {                            # mkv <file> <json findings array>
  printf '{"coverage":{"reviewed":[],"skipped":[],"unverified":[],"blocked_commands":[]},"findings":%s,"overall":{"verdict":"fix-required","summary":"x"}}\n' "$2" > "$1"
}
cnt() { node -e 'const m=require(process.argv[1]);const c=m.consensus.counts;console.log(c.agreed+" "+c.only_first+" "+c.only_second)' "$1"; }

# 1) Same defect, different words, lines +-1 -> must pair
mkv "$T/v1.json" '[{"file":"a.py","line":9,"severity":"minor","claim":"Money amounts computed with float and rounding lose fractions of a cent","why":"binary arithmetic accumulates error"}]'
mkv "$T/v2.json" '[{"file":"a.py","line":8,"severity":"major","claim":"Monetary total computed with float and round returns a value one cent short","why":"binary float cannot represent decimal prices exactly"}]'
bash "$CONS" --merge-only "$T/v1.json" "$T/v2.json" one two "$T/m.json" >/dev/null 2>&1
[ "$(cnt "$T/m.json")" = "1 0 0" ] && ok "one defect described two ways -> paired" \
  || bad "matching by meaning" "got: $(cnt "$T/m.json")"

# 2) Different defects on the SAME line -> must NOT pair
mkv "$T/v1.json" '[{"file":"a.py","line":5,"severity":"major","claim":"Missing permission check on the endpoint","why":"the role is not verified"}]'
mkv "$T/v2.json" '[{"file":"a.py","line":5,"severity":"major","claim":"Memory leak while processing large uploads","why":"the buffer is not released"}]'
bash "$CONS" --merge-only "$T/v1.json" "$T/v2.json" one two "$T/m.json" >/dev/null 2>&1
[ "$(cnt "$T/m.json")" = "0 1 1" ] && ok "a shared line with no shared meaning creates no pair" \
  || bad "false pair from the line number" "got: $(cnt "$T/m.json")"

# 2b) Different defects, same line, one shared STOP word -> still not a pair.
# The earlier formula added the tiny similarity of "never" to a perfect line
# match and crossed the threshold, reporting two unrelated findings as agreement.
mkv "$T/v1.json" '[{"file":"a.py","line":5,"severity":"major","claim":"Missing permission check on the endpoint","why":"the role is never verified"}]'
mkv "$T/v2.json" '[{"file":"a.py","line":5,"severity":"major","claim":"Memory leak while uploading files","why":"the buffer is never released"}]'
bash "$CONS" --merge-only "$T/v1.json" "$T/v2.json" one two "$T/m.json" >/dev/null 2>&1
[ "$(cnt "$T/m.json")" = "0 1 1" ] && ok "a shared stop word creates no pair" \
  || bad "stop word created a false pair" "got: $(cnt "$T/m.json")"

# 2c) Same defect, lines far apart -> pair anyway (proximity only ranks)
mkv "$T/v1.json" '[{"file":"a.py","line":100,"severity":"major","claim":"discount percentage is not bounded by a range","why":"a negative order total becomes possible"}]'
mkv "$T/v2.json" '[{"file":"a.py","line":5,"severity":"major","claim":"an unbounded discount percentage yields a negative order total","why":"there is no range validation on the percentage"}]'
bash "$CONS" --merge-only "$T/v1.json" "$T/v2.json" one two "$T/m.json" >/dev/null 2>&1
[ "$(cnt "$T/m.json")" = "1 0 0" ] && ok "meaning outweighs distance: far-apart lines paired" \
  || bad "distance outweighed meaning" "got: $(cnt "$T/m.json")"

# 3) Same defect, different files -> not a pair
mkv "$T/v1.json" '[{"file":"a.py","line":5,"severity":"major","claim":"Discount range check is missing","why":"the percentage is unbounded"}]'
mkv "$T/v2.json" '[{"file":"b.py","line":5,"severity":"major","claim":"Discount range check is missing","why":"the percentage is unbounded"}]'
bash "$CONS" --merge-only "$T/v1.json" "$T/v2.json" one two "$T/m.json" >/dev/null 2>&1
[ "$(cnt "$T/m.json")" = "0 1 1" ] && ok "different files form no pair" \
  || bad "pair across files" "got: $(cnt "$T/m.json")"

# 4) One run empty -> degraded summary, not a crash
mkv "$T/v1.json" '[{"file":"a.py","line":5,"severity":"major","claim":"Range check is missing","why":"no bounds at all"}]'
: > "$T/v2.json"
bash "$CONS" --merge-only "$T/v1.json" "$T/v2.json" one two "$T/m.json" >/dev/null 2>&1
deg=$(node -e 'console.log(require(process.argv[1]).consensus.degraded)' "$T/m.json" 2>/dev/null)
[ "$deg" = true ] && ok "empty second run -> degraded, not silent agreement" \
  || bad "degraded was not set" "degraded=$deg"

echo
echo "== 7b. Consensus: injection, identical models, unusable verdicts =="
mkdir -p "$T/cd" "$T/co"; echo x > "$T/cp"
CREQ="$T/cons.conf"
printf 'route=review\ndir=%s/cd\nout_dir=%s/co\nsubject=t\nprompt_file=%s/cp\nschema=%s/reference/review-schema.json\n' \
  "$T" "$T" "$T" "$(cd "$BIN/.." && pwd)" > "$CREQ"

# Injection through the second route NAME: a value containing a newline used to
# inject a second sed command with the /e flag and execute it.
rm -f "$T/PWNED"
EVIL=$'x/e\n s|^dir=.*|touch '"$T"'/PWNED|e\n#'
bash "$CONS" "$CREQ" "$EVIL" >/dev/null 2>&1
[ -f "$T/PWNED" ] && bad "injection through the route name" "COMMAND EXECUTED" \
                  || ok "injection through the route name does not work"

# The same model is a repeat, not independence
bash "$CONS" "$CREQ" plan >/dev/null 2>&1
[ $? -eq 2 ] && ok "review+plan (both terra/high) refused" || bad "identical models" "not refused"

# Nonexistent route
bash "$CONS" "$CREQ" nosuchroute >/dev/null 2>&1
[ $? -eq 2 ] && ok "nonexistent second route refused" || bad "nonexistent route" "-"

# Invalid JSON and a missing findings array must not pass as agreement
printf 'this is not json\n' > "$T/bad1.json"
mkv "$T/ok1.json" '[{"file":"a.py","line":5,"severity":"major","claim":"range check is missing","why":"no bounds at all"}]'
bash "$CONS" --merge-only "$T/ok1.json" "$T/bad1.json" one two "$T/mb.json" >/dev/null 2>&1
rc=$?
deg=$(node -e 'try{console.log(require(process.argv[1]).consensus.degraded)}catch(e){console.log("ERR")}' "$T/mb.json" 2>/dev/null)
{ [ "$deg" = true ] && [ "$rc" = 3 ]; } && ok "invalid JSON -> degraded and rc=3" \
  || bad "invalid JSON" "degraded=$deg rc=$rc"

printf '{}\n' > "$T/e1.json"; printf '{}\n' > "$T/e2.json"
bash "$CONS" --merge-only "$T/e1.json" "$T/e2.json" one two "$T/me.json" >/dev/null 2>&1
[ $? -ne 0 ] && ok "two empty objects do not pass as agreement" || bad "two {} reported success" "-"

# The same basename in different directories means different files
mkv "$T/p1.json" '[{"file":"src/config.js","line":10,"severity":"major","claim":"connection leaks when an error is raised","why":"the pool is not released"}]'
mkv "$T/p2.json" '[{"file":"tests/config.js","line":10,"severity":"major","claim":"connection leaks when an error is raised","why":"the pool is not released"}]'
bash "$CONS" --merge-only "$T/p1.json" "$T/p2.json" one two "$T/mp.json" >/dev/null 2>&1
[ "$(cnt "$T/mp.json")" = "0 1 1" ] && ok "same basename in different directories forms no pair" \
  || bad "basename merged different files" "got: $(cnt "$T/mp.json")"

echo
echo "== 7c. Failure-reason classification (stub codex) =="
CB="$T/cbin"; mkdir -p "$CB" "$T/fakepath" "$T/fo"
cp "$BIN/codex-run.sh" "$BIN/compat.sh" "$BIN/routes.conf" "$BIN/agents-anchor.txt" \
   "$BIN/expected-codex-version.txt" "$CB/"
mkdir -p "$T/cbin/../var"
cat > "$T/fakepath/codex" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *--version*)      echo "codex-cli 0.145.0"; exit 0 ;;
  *"login status"*) echo "Logged in using ChatGPT" >&2; exit 0 ;;
esac
# FAKE_CODEX_STDIN: copy what arrived on stdin, so a test can prove the prompt
# travelled as data. FAKE_CODEX_OUT: write a verdict to the -o path.
if [ -n "${FAKE_CODEX_STDIN:-}" ]; then cat > "$FAKE_CODEX_STDIN"; fi
if [ -n "${FAKE_CODEX_OUT:-}" ]; then
  prev=''; for a in "$@"; do [ "$prev" = -o ] && printf '%s' "$FAKE_CODEX_OUT" > "$a"; prev=$a; done
fi
printf '%s\n' "${FAKE_CODEX_ERR:-error: something}" >&2
exit "${FAKE_CODEX_RC:-1}"
FAKE
chmod +x "$T/fakepath/codex"
printf 'route=ping\ndir=%s/cd\nout_dir=%s/fo\nsubject=classifier\nprompt_file=%s/cp\n' \
  "$T" "$T" "$T" > "$T/fr.conf"
# A synthetic HOME, so this case does not depend on the developer's own Codex
# setup and runs identically on a bare CI machine. The runner's preflight reads
# $HOME/.codex/AGENTS.md and refuses without the anchor phrase.
FHOME="$T/fakehome"; mkdir -p "$FHOME/.codex"
cat "$BIN/agents-anchor.txt" > "$FHOME/.codex/AGENTS.md"
reason_of() {                      # reason_of <error text> -> REASON from the log
  rm -f "$CB/../var/calls.jsonl" "$T/var/preflight.ok"
  FAKE_CODEX_ERR="$1" HOME="$FHOME" PATH="$T/fakepath:$PATH" \
    bash "$CB/codex-run.sh" "$T/fr.conf" >/dev/null 2>&1
  node -e 'const fs=require("fs");const p=process.argv[1];if(!fs.existsSync(p)){console.log("NONE");process.exit(0)}
    const e=fs.readFileSync(p,"utf8").split("\n").filter(Boolean).map(JSON.parse).filter(x=>x.event==="finished");
    console.log(e.length?e[e.length-1].reason:"NONE")' "$CB/../var/calls.jsonl" 2>/dev/null
}
cls_case() { local got; got=$(reason_of "$1"); [ "$got" = "$2" ] && ok "$3 -> $2" || bad "$3" "got '$got', expected '$2'"; }
cls_case "Error: rate limit exceeded, try later"        RATE_LIMITED "quota"
cls_case "Error: not logged in. Run codex login"        AUTH         "authentication"
cls_case "Error: no rollout found for thread id abc"    NO_SESSION   "no session"
cls_case "Error: model gpt-x not found on this plan"    MODEL        "model"
cls_case "Error: ECONNREFUSED connecting to api"        NETWORK      "network"
cls_case "Error: something entirely unexpected"         UNKNOWN      "unrecognised"
# Ambiguity must give UNKNOWN, not the first class that happens to match
cls_case "Error: rate limit exceeded
Error: not logged in"                                    UNKNOWN      "two classes at once"

echo
echo "== 7d. The real call path: prompt as data, schema honoured =="
# Not a dry run. These use the stub codex, so they exercise the code that a
# dry run skips entirely.
rm -f "$T/TRACE_REAL"
printf 'harmless text\nPROMPT\n$(touch %s/TRACE_REAL) `id`\n' "$T" > "$T/realevil.txt"
printf 'route=ping\ndir=%s/cd\nout_dir=%s/fo\nsubject=real path\nprompt_file=%s/realevil.txt\n' \
  "$T" "$T" "$T" > "$T/real.conf"
FAKE_CODEX_STDIN="$T/got-stdin.txt" FAKE_CODEX_RC=0 FAKE_CODEX_OUT='a verdict' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/real.conf" >/dev/null 2>&1
if [ -f "$T/TRACE_REAL" ]; then bad "prompt executed on the real path" "FILE WAS CREATED"
elif [ -f "$T/got-stdin.txt" ] && grep -qF 'touch' "$T/got-stdin.txt"; then
  ok "prompt text reached codex verbatim on stdin, unexecuted"
else bad "prompt on the real path" "codex did not receive the prompt on stdin"; fi

# A route that asked for structured output must not accept prose. This is the
# case that let a diverted run report success: non-empty, non-whitespace, and
# not a verdict at all.
printf 'route=review\ndir=%s/cd\nout_dir=%s/fo\nsubject=schema check\nprompt_file=%s/cp\nschema=%s/reference/review-schema.json\n' \
  "$T" "$T" "$T" "$(cd "$BIN/.." && pwd)" > "$T/schema.conf"
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='I could not run the scan; press Start scan.' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "schema route refuses a non-JSON verdict" \
             || bad "schema route accepted prose" "this is the diverted-run false success"
# Parseable is not enough. `{"findings":[]}` is valid JSON meaning "no
# objections" -- a diverted run returning that used to pass as a clean review.
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='{"findings":[]}' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "JSON without coverage or a conclusion is refused" \
             || bad "incomplete JSON accepted" "the schema requires coverage and overall"
GOOD='{"coverage":{"reviewed":["a.sh"],"skipped":[],"unverified":[],"blocked_commands":[]},"findings":[],"overall":{"verdict":"ok","summary":"no objections"}}'
FAKE_CODEX_RC=0 FAKE_CODEX_OUT="$GOOD" \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -eq 0 ] && ok "a verdict complete per the schema is accepted" || bad "complete verdict refused" "$GOOD"
# A finding missing its required fields is the same lie one level deeper.
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='{"coverage":{"reviewed":["a.sh"],"skipped":[],"unverified":[],"blocked_commands":[]},"findings":[{"claim":"something is off"}],"overall":{"verdict":"ok","summary":"x"}}' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "a finding without severity or a locator is refused" \
             || bad "incomplete finding accepted" "the walk never reached the items of findings"
# One missing field at a time, or the case above would stay green under an
# implementation that checks severity and ignores locator entirely.
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='{"coverage":{"reviewed":["a.sh"],"skipped":[],"unverified":[],"blocked_commands":[]},"findings":[{"file":"a.sh","line":1,"severity":"minor","confidence":"certain","claim":"c","why":"w","check":"k"}],"overall":{"verdict":"ok","summary":"x"}}' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "a finding missing only locator is refused" \
             || bad "locator not required" "the test above passed on severity alone"
# Required fields present, types wrong. Without a type check this passed, and
# {"verdict":false,"summary":1} is structure without content.
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='{"coverage":{"reviewed":[1],"skipped":[],"unverified":[],"blocked_commands":[]},"findings":[],"overall":{"verdict":false,"summary":1}}' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "right fields with wrong types are refused" \
             || bad "types are not checked" "the walk only looks at required"
# ["string","null"] unions are used by the schema itself and must keep passing.
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='{"coverage":{"reviewed":["a.sh"],"skipped":[],"unverified":[],"blocked_commands":[]},"findings":[{"file":null,"line":null,"locator":"item 3","severity":"minor","confidence":"hypothesis","claim":"c","why":"w","check":"k"}],"overall":{"verdict":"fix-required","summary":"s"}}' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -eq 0 ] && ok "null in [string,null] fields is accepted" \
             || bad "type union refused" "a finding with no file and no line is legal per the schema"
# An empty coverage.reviewed means nothing was read -- the exact shape of a
# diverted run. Structurally the reply below is complete.
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='{"coverage":{"reviewed":[],"skipped":[],"unverified":[],"blocked_commands":[]},"findings":[],"overall":{"verdict":"ok","summary":"looks fine"}}' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "an empty coverage.reviewed is refused" \
             || bad "empty coverage accepted" "structurally complete, and nothing was read"
# Unions on the array side: items must still be walked for ["array","null"].
printf '{"type":"object","required":["names"],"properties":{"names":{"type":["array","null"],"items":{"type":"string"}}}}\n' > "$T/union-schema.json"
printf 'route=review\ndir=%s/cd\nout_dir=%s/fo\nsubject=union schema\nprompt_file=%s/cp\nschema=%s/union-schema.json\n' \
  "$T" "$T" "$T" "$T" > "$T/us.conf"
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='{"names":[1]}' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/us.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "items are walked through an [array,null] union" \
             || bad "union array items skipped" "sch.type===\"array\" is false for a union"
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='{"names":null}' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/us.conf" >/dev/null 2>&1
[ $? -eq 0 ] && ok "null is still legal for that union" || bad "union null refused" "-"
# minItems is honoured where a schema states it.
printf '{"type":"object","required":["names"],"properties":{"names":{"type":"array","minItems":1,"items":{"type":"string"}}}}\n' > "$T/min-schema.json"
printf 'route=review\ndir=%s/cd\nout_dir=%s/fo\nsubject=minItems\nprompt_file=%s/cp\nschema=%s/min-schema.json\n' \
  "$T" "$T" "$T" "$T" > "$T/ms.conf"
FAKE_CODEX_RC=0 FAKE_CODEX_OUT='{"names":[]}' \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/ms.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "minItems is enforced" || bad "minItems ignored" "-"
# An unparseable schema file must fail closed as well.
printf 'not json at all\n' > "$T/broken-schema.json"
printf 'route=review\ndir=%s/cd\nout_dir=%s/fo\nsubject=broken schema\nprompt_file=%s/cp\nschema=%s/broken-schema.json\n' \
  "$T" "$T" "$T" "$T" > "$T/bs.conf"
FAKE_CODEX_RC=0 FAKE_CODEX_OUT="$GOOD" \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/bs.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "an unparseable schema fails closed" \
             || bad "broken schema passed" "a check that reports fine when it breaks"

# No usable validator must FAIL CLOSED. "Could not check" reported as success is
# the same shape of failure the check was added to catch.
printf '#!/bin/sh\nexit 127\n' > "$T/fakepath/node"; chmod +x "$T/fakepath/node"
FAKE_CODEX_RC=0 FAKE_CODEX_OUT="$GOOD" \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -ne 0 ] && ok "schema route refuses when no validator is available" \
             || bad "no validator reported as success" "this is fail-open"
rm -f "$T/fakepath/node"
FAKE_CODEX_RC=0 FAKE_CODEX_OUT="$GOOD" \
  HOME="$FHOME" PATH="$T/fakepath:$PATH" bash "$CB/codex-run.sh" "$T/schema.conf" >/dev/null 2>&1
[ $? -eq 0 ] && ok "and passes again once the validator is back" || bad "validator removal was sticky" "-"

echo
echo "== 7d2. Switch fields: an enumeration, not a silent default =="
# `ephemeral=yees` used to be accepted and silently mean "no": the value is
# compared against `yes` when the flag is assembled, so a typo turned the
# session persistent instead of stopping the call.
req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" subject=typo \
    prompt_file="$T/p.txt" ephemeral=yees
expect_rc 2 "ephemeral with a typo is refused"
req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" subject=ephemeral \
    prompt_file="$T/p.txt" ephemeral=yes
o=$(dry "$T/r.conf"); has "$o" --ephemeral && ok "ephemeral=yes produces --ephemeral" \
  || bad "ephemeral=yes" "the flag is missing from argv"
req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" subject=explicit-no \
    prompt_file="$T/p.txt" ephemeral=no
o=$(dry "$T/r.conf"); has "$o" --ephemeral && bad "ephemeral=no" "the flag is spurious" \
  || ok "ephemeral=no adds no flag"
# An explicitly empty value is a malformed value, not an omission: a non-empty
# test would let it through and restore the silent default through the back door.
req "$T/r.conf" route=review dir="$T/work" out_dir="$T/out" subject=empty \
    prompt_file="$T/p.txt" ephemeral=
expect_rc 2 "an empty ephemeral= is refused"
req "$T/r.conf" route=review-critical dir="$T/work" out_dir="$T/out" subject=empty-bg \
    prompt_file="$T/p.txt" confirm_background=
expect_rc 2 "an empty confirm_background= is refused"
# confirm_background must obey `allows` like every other field.
req "$T/r.conf" route=ping dir="$T/work" out_dir="$T/out" subject=bg-on-foreground \
    prompt_file="$T/p.txt" confirm_background=yes
expect_rc 2 "confirm_background on a foreground route is refused"
req "$T/r.conf" route=review-critical dir="$T/work" out_dir="$T/out" subject=bg \
    prompt_file="$T/p.txt" confirm_background=yes
expect_rc "$DRYRC" "confirm_background on a background route is accepted"
# Image sessions pile up on disk, so the image routes have to accept ephemeral.
req "$T/r.conf" route=image-draft dir="$T/assets" out_dir="$T/out" subject=image \
    prompt_file="$T/p.txt" image="$T/a.png" ephemeral=yes confirm_background=yes
o=$(dry "$T/r.conf"); rcg=$(rc_dry "$T/r.conf")
{ [ "$rcg" = "$DRYRC" ] && has "$o" --ephemeral; } \
  && ok "an image route accepts ephemeral" || bad "ephemeral on image-draft" "rc=$rcg"

echo
echo "== 7e. Registry: a repeated field inside one route is refused =="
awk '/^route: ping$/{print; print "allows: image"; next} {print}' "$REG" > "$C/routes.conf"
req "$T/r.conf" route=ping dir="$T/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt"
got=$(RUNX="$C/codex-run.sh" rc_dry "$T/r.conf")
[ "$got" = 2 ] && ok "duplicate 'allows' refused (it would silently widen privilege)" \
               || bad "duplicate registry field accepted" "rc=$got"
unset RUNX

echo
echo "== 7f. Consensus: route names are identifiers =="
for badroute in $'review\n#' 'review;x' '../etc' ''; do
  bash "$CONS" "$CREQ" "$badroute" >/dev/null 2>&1
  [ $? -eq 2 ] && ok "route name refused: $(printf '%s' "$badroute" | tr '\n' '~')" \
               || bad "route name accepted" "$(printf '%s' "$badroute" | tr '\n' '~')"
done
bash "$CONS" --merge-only "$T/v1.json" "$T/v2.json" same same "$T/mx.json" >/dev/null 2>&1
[ $? -eq 2 ] && ok "merge-only refuses two identical labels (they collide as JSON keys)" \
             || bad "identical labels accepted" "half the findings would be overwritten"

echo
echo "== 7g. Consensus: hostile verdict content =="
mkv "$T/k1.json" '[{"file":"a.py","line":5,"severity":"major","claim":"range check missing","why":"no bounds","__k":"FORCED"}]'
mkv "$T/k2.json" '[{"file":"b.py","line":5,"severity":"major","claim":"range check missing","why":"no bounds","__k":"FORCED"}]'
bash "$CONS" --merge-only "$T/k1.json" "$T/k2.json" one two "$T/mk.json" >/dev/null 2>&1
[ "$(cnt "$T/mk.json")" = "0 1 1" ] && ok "an injected __k cannot force agreement across files" \
  || bad "__k injection worked" "got: $(cnt "$T/mk.json")"

# "exit code was non-zero" is not enough here: an unhandled TypeError also
# exits non-zero, so the assertion has to distinguish a refusal from a crash.
mkv "$T/t1.json" '[{"file":1,"line":5,"severity":"major","claim":"x","why":"y"}]'
mkv "$T/t2.json" '[{"file":"a.py","line":5,"severity":"major","claim":"x","why":"y"}]'
ERR=$(bash "$CONS" --merge-only "$T/t1.json" "$T/t2.json" one two "$T/mt.json" 2>&1); rc=$?
if printf '%s' "$ERR" | grep -q 'TypeError'; then bad "non-string file crashed the merge" "unhandled TypeError"
elif [ "$rc" -ne 0 ]; then ok "a finding with a non-string file is refused, not a crash"
else bad "wrong type accepted" "rc=0"; fi

mkv "$T/n1.json" '[{}]'; mkv "$T/n2.json" '[{}]'
bash "$CONS" --merge-only "$T/n1.json" "$T/n2.json" one two "$T/mn.json" >/dev/null 2>&1
[ $? -ne 0 ] && ok "an array of empty findings is not a usable verdict" \
             || bad "empty findings passed as agreement" "-"

# A verdict that is PARTLY malformed must be refused whole. Keeping the good
# elements and dropping the rest shrinks the verdict while still presenting it
# as a complete source.
mkv "$T/h1.json" '[{"file":"a.py","line":5,"severity":"major","claim":"range check missing","why":"no bounds"},{}]'
mkv "$T/h2.json" '[{"file":"a.py","line":5,"severity":"major","claim":"range check missing","why":"no bounds"}]'
bash "$CONS" --merge-only "$T/h1.json" "$T/h2.json" one two "$T/mh.json" >/dev/null 2>&1
deg=$(node -e 'try{const fs=require("fs");console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).consensus.degraded)}catch(e){console.log("ERR")}' "$T/mh.json" 2>/dev/null)
[ "$deg" = true ] && ok "a partly malformed verdict is refused, not silently trimmed" \
                  || bad "partial verdict accepted as whole" "degraded=$deg"

# The size cap must actually refuse, not merely be written down.
node -e '
const fs=require("fs");
const mk=n=>({coverage:{reviewed:[],skipped:[],unverified:[],blocked_commands:[]},
  findings:Array.from({length:n},(_,i)=>({file:"a.py",line:i,severity:"major",
    claim:"identical claim about the same thing",why:"identical reason"})),
  overall:{verdict:"fix-required",summary:"x"}});
fs.writeFileSync(process.argv[1],JSON.stringify(mk(600)));
fs.writeFileSync(process.argv[2],JSON.stringify(mk(600)));' "$T/big1.json" "$T/big2.json"
bash "$CONS" --merge-only "$T/big1.json" "$T/big2.json" one two "$T/mbig.json" >/dev/null 2>&1
[ $? -ne 0 ] && ok "a verdict past the findings cap is refused" \
             || bad "cap not enforced" "600 findings a side were accepted"

mkv "$T/c1.json" '[{"file":"Foo.js","line":5,"severity":"major","claim":"connection leaks on error","why":"pool not released"}]'
mkv "$T/c2.json" '[{"file":"foo.js","line":5,"severity":"major","claim":"connection leaks on error","why":"pool not released"}]'
bash "$CONS" --merge-only "$T/c1.json" "$T/c2.json" one two "$T/mc.json" >/dev/null 2>&1
[ "$(cnt "$T/mc.json")" = "0 1 1" ] && ok "Foo.js and foo.js are different files" \
  || bad "case folding merged two files" "got: $(cnt "$T/mc.json")"

# A relative output path must work. Both inputs are deliberately VALID here:
# with a degraded pair the run exits 3 either way, so the old require() bug
# would have passed the test. Demanding rc=0 and degraded=false is what makes
# this assertion sensitive to the fix.
mkv "$T/r1.json" '[{"file":"a.py","line":5,"severity":"major","claim":"discount percentage is not bounded","why":"a negative order total becomes possible"}]'
mkv "$T/r2.json" '[{"file":"a.py","line":6,"severity":"major","claim":"discount percentage is not bounded by a range","why":"a negative order total is possible"}]'
mkdir -p "$T/relout"
( cd "$T" && bash "$CONS" --merge-only "$T/r1.json" "$T/r2.json" one two "relout/r.json" >/dev/null 2>&1 )
rc=$?
deg=$(node -e 'try{const fs=require("fs");console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).consensus.degraded)}catch(e){console.log("ERR")}' "$T/relout/r.json" 2>/dev/null)
{ [ "$rc" -eq 0 ] && [ "$deg" = false ]; } && ok "a relative output path is read back correctly" \
  || bad "relative output path" "rc=$rc degraded=$deg"

echo
echo "== 7h. Portability layer: the timeout contract =="
# The pure-bash fallback is what macOS without coreutils actually runs, yet it
# was the one path with no test. It returned 143 on a timeout instead of 124,
# so the runner classified an aborted call as a generic failure.
cat > "$T/compat-probe.sh" <<'PROBE'
. "$1/compat.sh"
COMPAT_TIMEOUT_KIND=builtin            # force the fallback, even where timeout(1) exists
compat_timeout 1 sleep 10;       printf 'hung=%s\n' $?
compat_timeout 5 true;           printf 'fast=%s\n' $?
compat_timeout 5 sh -c 'exit 7'; printf 'fail=%s\n' $?
# stdin must survive the fallback. An asynchronous command with no explicit
# redirection gets /dev/null when job control is off, so the prompt reached
# Codex empty on every system without timeout(1) -- and the reviewer answered
# about nothing. Invisible on Linux and Windows, where timeout(1) exists, so
# it is pinned here in the exact form the runner uses: stdin from a FILE with
# stdout redirected. A pipe alone does not reproduce it.
printf 'STDIN-MARKER\n' > "$2/in.txt"
compat_timeout 5 cat < "$2/in.txt" > "$2/out.txt" 2>/dev/null
printf 'stdin=%s\n' "$(cat "$2/out.txt" 2>/dev/null)"
PROBE
P=$(bash "$T/compat-probe.sh" "$BIN" "$T" 2>/dev/null)
case $P in *hung=124*) ok "fallback timeout returns 124, as timeout(1) does" ;;
           *) bad "fallback timeout code" "got: $(printf '%s' "$P" | tr '\n' ' ')" ;; esac
case $P in *fast=0*)   ok "fallback passes through a success" ;;
           *) bad "fallback success code" "got: $(printf '%s' "$P" | tr '\n' ' ')" ;; esac
case $P in *fail=7*)   ok "fallback passes through the command's own exit code" ;;
           *) bad "fallback failure code" "got: $(printf '%s' "$P" | tr '\n' ' ')" ;; esac
case $P in *stdin=STDIN-MARKER*) ok "fallback keeps stdin: the prompt reaches the command" ;;
           *) bad "fallback loses stdin" "the prompt would arrive empty wherever timeout(1) is absent" ;; esac

# bash 3.2 compatibility cannot be proved by running under bash 5, and stock
# macOS is exactly where it matters. A static check is the honest substitute:
# it catches the reintroduction, which is the realistic failure.
# Anchored to COMMAND position. A looser pattern matched the comment in
# codex-run.sh that explains why declare -A was removed -- the same self-match
# trap that check-all.sh had to solve for `eval`.
B4=$(grep -lE '(^|[;&|{(]|then |else |do )[[:space:]]*(declare[[:space:]]+-A|local[[:space:]]+-n|mapfile[[:space:]]|readarray[[:space:]])' "$BIN"/*.sh 2>/dev/null)
[ -z "$B4" ] && ok "no bash-4-only construct in any script (stock macOS is bash 3.2)" \
             || bad "bash 4 construct found" "$(printf '%s' "$B4" | tr '\n' ' ')"

# The request file must be the ONLY source of request fields. Plain shell
# variables are inherited from the environment; an associative array was not.
req "$T/r.conf" route=plan-critical dir="$T/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt"
got=$(REQ_confirm_background=yes rc_dry "$T/r.conf")
[ "$got" = 3 ] && ok "REQ_confirm_background in the environment does not confirm anything" \
               || bad "environment satisfied the background gate" "rc=$got (3 expected)"
req "$T/r.conf" dir="$T/work" out_dir="$T/out" subject=x prompt_file="$T/p.txt"
got=$(REQ_route=ping rc_dry "$T/r.conf")
[ "$got" = 2 ] && ok "REQ_route in the environment cannot supply a missing route" \
               || bad "environment supplied the route" "rc=$got (2 expected)"

echo
echo "== 7i. check-all: the scan must read files, not just print ok =="
# The dangerous-construct scan went blind when the path contained a space:
# word splitting left grep with fragments, and zero matches read as clean.
# --scan-only, because the full check-all runs this very suite: a suite calling
# it would re-enter itself without end.
SP="$T/dir with space"; mkdir -p "$SP/bin"
cp "$BIN"/*.sh "$SP/bin/" 2>/dev/null
bash "$SP/bin/check-all.sh" --scan-only >/dev/null 2>&1 \
  && ok "clean sources pass the construct scan from a spaced path" \
  || bad "false positive from a spaced path" "clean sources were reported dirty"
printf '\nx=1\neval "$x"\n' >> "$SP/bin/codex-consensus.sh"
CA=$(bash "$SP/bin/check-all.sh" --scan-only 2>&1 | grep -c 'eval called in')
[ "$CA" -ge 1 ] && ok "a planted eval is reported even from a path containing a space" \
                || bad "the construct scan read nothing" "a real eval went unreported"

# The recursion guard, which is the reason --scan-only exists. check-all runs
# the suites; this suite runs check-all. Without the marker the two call each
# other forever, and killing the parent does not stop the children -- an
# interrupted run once left a process tree multiplying for three hours.
# A FULL check-all is invoked here, deliberately: if the guard is ever removed,
# this case is what hangs, and it hangs immediately rather than in production.
# Through compat_timeout, not timeout(1): this was the one direct call to
# timeout left in the suites, and a stock macOS has no such binary -- the
# command never ran, the guard was never printed, and the case failed on the
# platform the portability layer exists for.
GUARD=$( . "$SP/bin/compat.sh"
         CODEX_BRIDGE_IN_SUITE=1 compat_timeout 60 bash "$SP/bin/check-all.sh" 2>&1 \
           | grep -c 'recursion guard' )
[ "$GUARD" -ge 1 ] && ok "check-all refuses to run the suites from inside a suite" \
                   || bad "recursion guard missing" "check-all would re-enter itself without end"

echo
echo "== 8. The SKILL.md route table is in sync with the registry =="
if bash "$BIN/gen-routes-table.sh" --check >/dev/null 2>&1; then ok "gen-routes-table --check"
else bad "gen-routes-table --check" "the table has drifted from the registry"; fi

echo
if [ "$SKIP" -gt 0 ]; then printf '\nTOTAL: passed %d, failed %d, skipped %d\n' "$PASS" "$FAIL" "$SKIP"
else printf '\nTOTAL: passed %d, failed %d\n' "$PASS" "$FAIL"; fi
[ "$FAIL" -eq 0 ]
