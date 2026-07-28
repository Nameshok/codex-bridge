#!/usr/bin/env bash
# test-snapshot.sh -- edge cases for codex-snapshot.sh.
#
# Every case here is one this script once got wrong: a dirty tree, a merge commit
# whose patch printed empty, a secret gate that failed open, a root commit with
# no parent, and names with spaces and non-ASCII characters.

set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SNAP="$BIN/codex-snapshot.sh"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
# A case this platform cannot construct is not a pass. Calling it one is how a
# suite comes to look green where it proved nothing.
skip() { SKIP=$((SKIP+1)); printf '  skip %s\n       %s\n' "$1" "$2"; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

newrepo() {                    # newrepo <name> -> path
  local r="$T/$1"; mkdir -p "$r"; cd "$r" || return 1
  git init -q .
  git config user.email t@t; git config user.name t
  git config commit.gpgsign false
  git config core.autocrlf false        # otherwise the output drowns in LF/CRLF warnings
  printf '%s' "$r"
}
run()  { bash "$SNAP" "$@" 2>/dev/null; }
rcof() { bash "$SNAP" "$@" >/dev/null 2>&1; printf '%s' $?; }
base() { run "$1" | grep '^BASE=' | cut -d= -f2; }
mrg()  { run "$1" | grep '^MERGE=' | cut -d= -f2; }

echo "== 1. Repository with no commits: refuse, do not crash =="
R=$(newrepo empty)
[ "$(rcof "$R")" = 1 ] && ok "no commits -> rc=1" || bad "no commits" "rc=$(rcof "$R")"

echo
echo "== 2. Clean tree: BASE is HEAD =="
R=$(newrepo clean); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
H=$(git rev-parse HEAD)
[ "$(base "$R")" = "$H" ] && ok "BASE=HEAD" || bad "clean tree" "BASE=$(base "$R") HEAD=$H"
[ "$(mrg "$R")" = no ] && ok "MERGE=no" || bad "MERGE" "$(mrg "$R")"

echo
echo "== 3. Dirty tree: the snapshot takes the edits, the working index is untouched =="
R=$(newrepo dirty); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
echo two >> a.txt                       # unstaged
echo new > b.txt; git add b.txt         # staged
echo untr > c.txt                       # untracked
STAGED_BEFORE=$(git diff --cached --name-only | sort | tr '\n' ' ')
B=$(base "$R"); H=$(git rev-parse HEAD)
{ [ -n "$B" ] && [ "$B" != "$H" ]; } && ok "BASE is a new snapshot, not HEAD" || bad "dirty tree" "BASE=$B HEAD=$H"
FILES=$(bash "$SNAP" --files "$R" "$B" 2>/dev/null | sort | tr '\n' ' ')
case "$FILES" in *a.txt*b.txt*c.txt*) ok "snapshot contains unstaged, staged and untracked" ;;
                 *) bad "snapshot coverage" "got: $FILES" ;; esac
STAGED_AFTER=$(git diff --cached --name-only | sort | tr '\n' ' ')
[ "$STAGED_BEFORE" = "$STAGED_AFTER" ] && ok "working index unchanged" \
  || bad "working index" "was [$STAGED_BEFORE] now [$STAGED_AFTER]"
PATCH=$(git show --format= "$B" | wc -l)
[ "$PATCH" -gt 0 ] && ok "git show on the snapshot yields a non-empty patch ($PATCH lines)" \
  || bad "snapshot patch is empty" "this is the stash-create disease: exactly one parent is required"

echo
echo "== 4. The secret gate stops, it does not warn =="
R=$(newrepo secret); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
printf 'KEY=1\n' > .env
[ "$(rcof "$R")" = 2 ] && ok "untracked .env -> rc=2" || bad ".env gate" "rc=$(rcof "$R")"
rm .env; printf 'x\n' > id_ed25519
[ "$(rcof "$R")" = 2 ] && ok "untracked id_ed25519 -> rc=2" || bad "key gate" "rc=$(rcof "$R")"
rm id_ed25519; printf 'x\n' > client.session
[ "$(rcof "$R")" = 2 ] && ok "untracked client.session -> rc=2" || bad "session gate" "rc=$(rcof "$R")"
rm client.session
# The suffix form is what an anchored (^|/)\.env pattern used to miss
printf 'K=1\n' > prod.env
[ "$(rcof "$R")" = 2 ] && ok "untracked prod.env -> rc=2" || bad "prod.env gate" "rc=$(rcof "$R")"
rm prod.env; printf 'K=1\n' > .env.local
[ "$(rcof "$R")" = 2 ] && ok "untracked .env.local -> rc=2" || bad ".env.local gate" "rc=$(rcof "$R")"
rm .env.local
# Forms the earlier pattern let through
for n in '.env~' '.env-backup' 'private.pem.bak' 'client.key.old' 'id_dsa' \
         'kubeconfig' 'keystore.jks' 'passwords.kdbx' '.netrc' 'api_key.txt'; do
  printf 'x\n' > "$n"
  [ "$(rcof "$R")" = 2 ] && ok "gate catches $n" || bad "gate missed $n" "rc=$(rcof "$R")"
  rm -f "$n"
done
# And a check that the widened pattern does not swallow neighbouring words
echo x > .environment; echo y > mail.envelope
[ "$(rcof "$R")" = 0 ] && ok ".environment and .envelope are not false positives" \
                       || bad "false positive" "rc=$(rcof "$R")"
rm .environment mail.envelope
[ "$(rcof "$R")" = 0 ] && ok "a repository with no secrets passes" || bad "false positive" "rc=$(rcof "$R")"

echo
echo "== 4a. Not only untracked: staged and tracked files enter the snapshot too =="
R=$(newrepo staged); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
printf 'K=1\n' > .env; git add .env          # STAGED but not committed
[ "$(rcof "$R")" = 2 ] && ok "staged .env -> rc=2" || bad "gate missed staged .env" "rc=$(rcof "$R")"
git commit -qm "add .env"                     # now TRACKED
[ "$(rcof "$R")" = 2 ] && ok "tracked .env -> rc=2" || bad "gate missed tracked .env" "rc=$(rcof "$R")"

echo
echo "== 4a2. Gate 1 catches EVERY executable key in the local config =="
R=$(newrepo execcfg); cd "$R"
echo ok > a.txt; git add -A; git commit -qm init
cfg_case() {                       # cfg_case <key> <value> <label>
  git config "$1" "$2"
  local rc; rc=$(rcof "$R")
  [ "$rc" = 2 ] && ok "$3" || bad "$3" "rc=$rc -- key $1 was missed"
  git config --unset "$1" 2>/dev/null
}
cfg_case filter.x.clean   'sh -c cat'      "filter.*.clean"
cfg_case filter.x.smudge  'sh -c cat'      "filter.*.smudge"
cfg_case diff.x.textconv  'sh -c cat'      "diff.*.textconv"
cfg_case diff.x.command   'sh -c cat'      "diff.*.command"
cfg_case core.fsmonitor   'sh -c true'     "core.fsmonitor"
cfg_case core.hooksPath   '/tmp/h'         "core.hooksPath"
cfg_case core.sshCommand  'ssh -v'         "core.sshCommand"
cfg_case core.pager       'less'           "core.pager"
cfg_case core.editor      'vi'             "core.editor"
cfg_case gpg.program      '/tmp/gpg'       "gpg.program"
cfg_case sequence.editor  'vi'             "sequence.editor"
[ "$(rcof "$R")" = 0 ] && ok "no executable keys -> passes" || bad "false positive" "rc=$(rcof "$R")"
# Key values must never be printed: one of them may carry a token
git config core.sshCommand 'ssh -i /secret/key -o User=TOKEN123'
ERR=$(bash "$SNAP" "$R" 2>&1 >/dev/null)
printf '%s' "$ERR" | grep -q 'TOKEN123' && bad "config value printed" "leak" \
                                        || ok "the value of an executable key is not printed"
git config --unset core.sshCommand

echo
echo "== 4a3. textconv does NOT execute while the patch is built =="
R=$(newrepo textconv); cd "$R"
echo hello > file.dat; git add -A; git commit -qm init
MARK="$T/TEXTCONV_RAN"; rm -f "$MARK"
git config diff.evil.textconv "sh -c 'touch $MARK; cat'"
printf '*.dat diff=evil\n' > .gitattributes
echo world >> file.dat
rc=$(rcof "$R")
if [ -f "$MARK" ]; then bad "textconv executed" "a repository-supplied command ran while building the patch"
elif [ "$rc" = 2 ]; then ok "textconv stopped by the gate, the command never ran"
else bad "textconv" "rc=$rc, neither stopped nor executed"; fi

echo
echo "== 4a3b. A filter hidden behind include.path is still caught =="
# git config --local does NOT expand include.path, but git add does. Without
# --includes the gate saw nothing and the planted command ran; reproduced.
R=$(newrepo included); cd "$R"
echo one > a.txt; git add -A; git commit -qm init
MARK="$T/INCLUDE_FILTER_RAN"; rm -f "$MARK"
git config --file .git/extra.cfg filter.evil.clean "sh -c \"touch $MARK; cat\""
printf '[include]\n\tpath = extra.cfg\n' >> .git/config
printf '* filter=evil\n' > .gitattributes
echo two >> a.txt
rc=$(rcof "$R")
if [ -f "$MARK" ]; then bad "include.path filter executed" "repository code ran during git add"
elif [ "$rc" = 2 ]; then ok "filter behind include.path stops the snapshot (rc=2)"
else bad "include.path filter" "rc=$rc, neither stopped nor executed"; fi
# The SECOND lookup -- the per-key loop -- needs its own case, or removing
# --includes from just that one would go unnoticed: the filter above is caught
# by the get-regexp lookup alone.
R=$(newrepo included2); cd "$R"
echo one > a.txt; git add -A; git commit -qm init
git config --file .git/extra.cfg core.sshCommand 'ssh -v'
printf '[include]\n\tpath = extra.cfg\n' >> .git/config
[ "$(rcof "$R")" = 2 ] && ok "core.* behind include.path is caught by the per-key lookup" \
                       || bad "per-key lookup misses includes" "rc=$(rcof "$R")"

# ...and a global filter must still NOT be caught, or every repo on a machine
# with git-lfs would be refused.
R=$(newrepo notglobal); cd "$R"
echo one > a.txt; git add -A; git commit -qm init
[ "$(rcof "$R")" = 0 ] && ok "a repository with no local config still passes" \
                       || bad "gate too broad" "rc=$(rcof "$R")"

echo
echo "== 4a5. A control character in a file name is refused, not misread =="
R=$(newrepo ctrlname); cd "$R"
echo one > a.txt; git add -A; git commit -qm init
# git C-quotes such a name, so the name pattern never sees a plain ".env".
# NTFS rejects a newline in a filename outright, so the case is skipped rather
# than failed there -- a test that cannot construct its input proves nothing
# either way, and saying so is better than a red line about the filesystem.
# Whether this case even exists is decided by GIT's output, not by whether the
# file could be created. Windows accepts the redirect but remaps the newline
# into a private-use character, so nothing is quoted and there is nothing to
# assert; asserting anyway would produce a red line about the filesystem rather
# than about the gate.
NLNAME=$(printf '.env\nx')
printf 'K=1\n' > "$NLNAME" 2>/dev/null
QSEEN=$(git -c core.quotepath=false ls-files --others --exclude-standard | grep -c '^"' || true)
if [ "${QSEEN:-0}" -gt 0 ]; then
  [ "$(rcof "$R")" = 2 ] && ok "name with a control character -> rc=2" \
                         || bad "control character in a name" "rc=$(rcof "$R")"
else
  skip "control character in a file name" \
       "this platform remaps or rejects it, so the gate is not exercised here"
fi
rm -f "$NLNAME" 2>/dev/null

echo
echo "== 4a4. Colour does not blind the content scanner =="
R=$(newrepo colorblind); cd "$R"
echo ok > a.txt; git add -A; git commit -qm init
git config color.diff always; git config color.ui always
printf 'k = "AKIAIOSFODNN7EXAMPLE"\n' > cfg.py
[ "$(rcof "$R")" = 2 ] && ok "secret found with color.diff=always" \
  || bad "colour blinded the gate" "rc=$(rcof "$R")"
# ...and the value is not printed
ERR=$(bash "$SNAP" "$R" 2>&1 >/dev/null)
printf '%s' "$ERR" | grep -qE 'AKIA[A-Z0-9]' && bad "secret value printed" "leak through the report" \
                                             || ok "not one character of the value is in the report"
printf '%s' "$ERR" | grep -q 'AWS access key' && ok "the kind of match is named" || bad "kind not named" "-"

echo
echo "== 4b. Fail-closed: a broken grep must not open the gate =="
R=$(newrepo failclosed); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
REALGREP=$(command -v grep)
FAKE="$T/fakebin"; mkdir -p "$FAKE"
# One gate at a time. A stub that breaks EVERY grep proves almost nothing: with
# all of them broken, deleting the fail-closed branch from one gate still leaves
# another gate to return 2, and the test stays green over a real regression.
# Each stub below fails for exactly one gate's pattern and delegates the rest.
break_grep_for() {                 # break_grep_for <substring of the pattern>
  cat > "$FAKE/grep" <<STUB
#!/bin/sh
case "\$*" in *'$1'*) exit 2 ;; esac
exec "$REALGREP" "\$@"
STUB
  chmod +x "$FAKE/grep"
  PATH="$FAKE:$PATH" bash "$SNAP" "$R" >/dev/null 2>&1; printf '%s' $?
}
rc=$(break_grep_for 'id_ed25519')
[ "$rc" = 2 ] && ok "name gate alone breaks -> rc=2" \
              || bad "name gate failed open" "rc=$rc"
rc=$(break_grep_for '^\+')
[ "$rc" = 2 ] && ok "added-lines selection alone breaks -> rc=2" \
              || bad "content gate failed open on line selection" "rc=$rc"
rc=$(break_grep_for 'AKIA')
[ "$rc" = 2 ] && ok "one content class alone breaks -> rc=2" \
              || bad "content gate failed open on a class check" "rc=$rc"
# And the stub itself must be innocent when it breaks nothing, or the three
# results above would prove only that the stub is present.
cat > "$FAKE/grep" <<STUB
#!/bin/sh
exec "$REALGREP" "\$@"
STUB
chmod +x "$FAKE/grep"
rc=$(PATH="$FAKE:$PATH" bash "$SNAP" "$R" >/dev/null 2>&1; printf '%s' $?)
[ "$rc" = 0 ] && ok "a pass-through stub changes nothing (rc=0)" \
              || bad "the stub itself broke the run" "rc=$rc"
rm -rf "$FAKE"

echo
echo "== 4c. A repository that runs its own code on git add =="
R=$(newrepo filters); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
git config filter.evil.clean 'sh -c "touch FILTER_RAN; cat"'
printf '* filter=evil\n' > .gitattributes
rc=$(rcof "$R")
if [ -f FILTER_RAN ]; then bad "clean filter" "FILTER EXECUTED -- repository code ran"
elif [ "$rc" = 2 ]; then ok "a clean filter in the config stops the snapshot (rc=2)"
else bad "clean filter" "rc=$rc, the filter did not run but the gate did not fire either"; fi

echo
echo "== 5. Names with spaces and non-ASCII characters =="
R=$(newrepo unicode); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
# The non-ASCII names are built from escapes so that this test file itself stays
# pure ASCII: the bytes under test must not depend on how an editor saved it.
UTF8_NAME=$(printf 'caf\303\251 men\303\274.md')
UTF8_ENV=$(printf 'secret caf\303\251.env')
echo x > "file with space.txt"
echo y > "$UTF8_NAME"
B=$(base "$R")
FILES=$(bash "$SNAP" --files "$R" "$B" 2>/dev/null)
if printf '%s\n' "$FILES" | grep -qF 'file with space' && printf '%s\n' "$FILES" | grep -qF "$UTF8_NAME"; then
  ok "spaces and non-ASCII entered the snapshot and print unquoted"
else bad "spaces/non-ASCII" "got: $(printf '%s' "$FILES" | tr '\n' '|')"; fi
printf 'KEY=1\n' > "$UTF8_ENV"
[ "$(rcof "$R")" = 2 ] && ok "gate catches a .env with a space and non-ASCII in the name" \
                       || bad "gate on a non-ASCII name" "rc=$(rcof "$R")"
rm "$UTF8_ENV"

echo
echo "== 6. detached HEAD =="
R=$(newrepo detached); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
echo two > a.txt; git add -A; git commit -qm two
git checkout -q HEAD~1
echo three >> a.txt
B=$(base "$R")
[ -n "$B" ] && ok "a snapshot assembles on a detached HEAD" || bad "detached HEAD" "BASE is empty"

echo
echo "== 7. merge HEAD: MERGE=yes and coverage through the diff form =="
R=$(newrepo merge); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
git checkout -q -b side; echo s > s.txt; git add -A; git commit -qm side
git checkout -q -; echo m > m.txt; git add -A; git commit -qm main
git merge -q --no-ff side -m merge >/dev/null 2>&1
[ "$(mrg "$R")" = yes ] && ok "MERGE=yes detected" || bad "merge detection" "$(mrg "$R")"
B=$(base "$R")
FILES=$(bash "$SNAP" --files "$R" "$B" 2>/dev/null)
[ -n "$FILES" ] && ok "--files on a merge gives a non-empty list ($(printf '%s' "$FILES" | tr '\n' ' '))" \
                || bad "merge coverage is empty" "this is exactly the silent failure the diff form fixes"

echo
echo "== 8. --files on a root commit (no parent) =="
R=$(newrepo root); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
B=$(git rev-parse HEAD)
FILES=$(bash "$SNAP" --files "$R" "$B" 2>/dev/null); rc=$?
{ [ $rc -eq 0 ] && [ -n "$FILES" ]; } && ok "no 'unknown revision' failure" \
  || bad "root commit" "rc=$rc, output: $FILES"

echo
echo "== 8a. CONTENT scanner: a secret under a neutral file name =="
R=$(newrepo content); cd "$R"
echo ok > readme.md; git add -A; git commit -qm init
# The names are deliberately ones the name gate cannot see
scan_case() {                      # <file name> <line> <expected rc> <label>
  printf '%s\n' "$2" > "$1"
  local rc; rc=$(rcof "$R")
  [ "$rc" = "$3" ] && ok "$4" || bad "$4" "expected rc=$3, got rc=$rc"
  rm -f "$1"
}
scan_case config.yml  'key: AKIAIOSFODNN7EXAMPLE'                                  2 "AWS key in config.yml"
scan_case data.txt    '-----BEGIN RSA PRIVATE KEY-----'                            2 "private key in data.txt"
scan_case handler.py  'session = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdef"'    2 "JWT in handler.py"
scan_case deploy.py   'GH = "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"'            2 "GitHub token in deploy.py"
scan_case settings.py 'client_secret = "aB3dEfGh1jKlMn0pQrStUvWx"'                 2 "client_secret in settings.py"
scan_case google.py   'k = "AIzaSyA1234567890abcdefghijklmnopqrstuv"'              2 "Google key in google.py"
# Forms that a narrower pattern would let through
scan_case cfg.json    '  "client_secret": "aB3dEfGh1jKlMn0pQrStUvWx"'             2 "JSON with a quote after the key"
scan_case pgp.txt     '-----BEGIN PGP PRIVATE KEY BLOCK-----'                     2 "PGP PRIVATE KEY BLOCK"
scan_case ssh.txt     '-----BEGIN OPENSSH PRIVATE KEY-----'                       2 "OPENSSH PRIVATE KEY"
scan_case ec.txt      '-----BEGIN EC PRIVATE KEY-----'                            2 "EC PRIVATE KEY"
scan_case conf.yml    'api_key: aB3dEfGh1jKlMn0pQrStUvWx'                         2 "YAML api_key without quotes"
# Real code containing the words secret/password/token must NOT fire
cat > real.py <<'PY'
SECRET_KEY_SETTING = "django.conf.settings.SECRET_KEY"
def validate_password(password: str) -> bool:
    return len(password) >= 12
API_KEY_HEADER = "X-Api-Key"
tokenizer = load_tokenizer("bert-base")
PY
[ "$(rcof "$R")" = 0 ] && ok "ordinary code gives no false positive" \
                       || bad "false positive on code" "rc=$(rcof "$R")"
# Removing a secret must not stop the call: only ADDED lines are scanned
printf 'k = "AKIAIOSFODNN7EXAMPLE"\n' > old.py; git add -A; git commit -qm "had a secret"
rm old.py
[ "$(rcof "$R")" = 0 ] && ok "deleting a secret does not stop the call" \
                       || bad "deleting a secret" "rc=$(rcof "$R")"

echo
echo "== 8a2. A binary file is named as unscanned, not silently ignored =="
R=$(newrepo binary); cd "$R"
echo ok > readme.md; git add -A; git commit -qm init
# A NUL byte makes git treat the file as binary and print "Binary files differ"
# instead of the bytes, so the content gate cannot see anything inside it.
printf 'AKIAIOSFODNN7EXAMPLE\000\001\002binary\n' > blob.bin
ERR=$(bash "$SNAP" "$R" 2>&1 >/dev/null); rc=$(rcof "$R")
if printf '%s' "$ERR" | grep -q 'blob.bin'; then
  ok "the unscanned binary is named in the report"
else bad "binary not named" "the report points at nothing useful"; fi
printf '%s' "$ERR" | grep -q '/dev/null' \
  && bad "report names /dev/null" "a newly added binary must be named by its own path" \
  || ok "the report does not name /dev/null for a newly added binary"
printf '%s' "$ERR" | grep -qi 'NOT scanned' \
  && ok "the report says plainly that the contents were not scanned" \
  || bad "blindness not stated" "-"
[ "$rc" = 0 ] && ok "a binary file does not abort the run" || bad "binary aborted the run" "rc=$rc"

echo
echo "== 8b. Snapshot size is reported =="
R=$(newrepo volume); cd "$R"
echo one > a.txt; git add -A; git commit -qm init
# A bash loop, not seq: BSD userland is not guaranteed to have seq, and a test
# that fails for a missing tool reports a defect that is not there.
rep() { local i=0; while [ "$i" -lt "$2" ]; do printf '%s\n' "$1"; i=$((i+1)); done; }
rep x 50 > big.txt
OUT=$(run "$R")
printf '%s\n' "$OUT" | grep -q '^LINES=' && ok "LINES= present" || bad "no LINES=" "$OUT"
printf '%s\n' "$OUT" | grep -q '^FILES=' && ok "FILES= present" || bad "no FILES=" "$OUT"
L=$(printf '%s\n' "$OUT" | grep '^LINES=' | cut -d= -f2)
[ "${L:-0}" -gt 40 ] && ok "the size is counted plausibly ($L lines)" || bad "size" "LINES=$L"
# The large-patch warning.
# Output goes into a VARIABLE first, never `... | grep -q`: grep -q closes the
# pipe on the first match, the snapshot gets SIGPIPE, and pipefail makes the
# whole pipeline unsuccessful -- the check failed while the code worked.
rep y 2100 > huge.txt
BIGOUT=$(bash "$SNAP" "$R" 2>&1)
printf '%s\n' "$BIGOUT" | grep -qF 'PATCH IS LARGER THAN 2000 LINES' \
  && ok "a large patch produces a warning" \
  || bad "no large-patch warning" "$(printf '%s' "$BIGOUT" | grep -c .) lines of output"

echo
echo "== 9. The script does not spray its own errors into stderr =="
R=$(newrepo noise); cd "$R"
echo one > a.txt; git add -A; git commit -qm one
echo two >> a.txt
ERR=$(bash "$SNAP" "$R" 2>&1 >/dev/null)
if printf '%s' "$ERR" | grep -qiE 'invalid option|usage:|command not found|unary operator'; then
  bad "clean stderr" "$(printf '%s' "$ERR" | head -2)"
else ok "stderr carries no errors from the script itself"; fi
printf '%s' "$ERR" | grep -q 'what goes into the snapshot' \
  && ok "the 'what goes in' header really is printed" \
  || bad "header not printed" "this is what a printf with a leading dash used to hide"

echo
if [ "$SKIP" -gt 0 ]; then printf '\nTOTAL: passed %d, failed %d, skipped %d\n' "$PASS" "$FAIL" "$SKIP"
else printf '\nTOTAL: passed %d, failed %d\n' "$PASS" "$FAIL"; fi
[ "$FAIL" -eq 0 ]
