#!/usr/bin/env bash
# codex-snapshot.sh -- a frozen snapshot of a git repository for review.
#
#   bash codex-snapshot.sh <repo>
#       build the snapshot; print BASE, MERGE, LINES, FILES
#
#   bash codex-snapshot.sh --files <repo> <sha>
#       print the files the snapshot contains (coverage check)
#
# Why a snapshot: a live working tree keeps changing while the reviewer reads
# it. A verdict about code that no longer exists is worse than no verdict -- it
# creates false confidence.
#
# Exit codes:
#   0  snapshot built
#   1  error (not a repository, no commits, git failed)
#   2  STOPPED by a gate: a secret, or executable configuration shipped with
#      the repository
#
# HONEST: this does write. add/write-tree/commit-tree put a blob, a tree and a
# commit into .git/objects. Working files, the index and refs are untouched and
# nothing uncommitted can be lost -- but the snapshot's contents, including a
# secret that slipped in, stay in the repository until garbage collection.
# That is why the gates STOP rather than warn.

set -uo pipefail

BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=compat.sh
. "$BIN_DIR/compat.sh"

die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }
say() { printf '%s\n' "$1" >&2; }   # not printf '<text>': a format starting
                                    # with a dash is parsed as an option

# Git runs code the REPOSITORY supplies: core.fsmonitor on git status, hooks on
# index operations, filter.<driver>.clean on git add, diff.<driver>.textconv on
# git show/diff. This is documented git behaviour, not an injection. Whatever
# can be switched off with a flag is switched off here; the rest is caught by
# gate 1 below.
GITSAFE=(git
  -c core.fsmonitor=false
  -c core.hooksPath=/dev/nonexistent-hooks
  -c core.pager=cat
  -c log.showSignature=false
  -c color.ui=false
)

# Flags for EVERY command that builds a patch. The configuration gate runs
# before the snapshot, but the patch is built afterwards -- and git executes
# textconv/external diff on the way. Verified: a planted textconv ran during
# git show and git diff; --no-textconv --no-ext-diff prevents it. --no-color is
# equally load-bearing: with color.diff=always the diff lines start with an
# ANSI escape, `grep '^\+'` matches nothing, and the content gate goes blind.
DIFFSAFE=(--no-textconv --no-ext-diff --no-color)

# ------------------------------------------------------------ mode --files

if [ "${1-}" = --files ]; then
  [ $# -eq 3 ] || die "usage: $0 --files <repo> <sha>"
  cd "$2" || die "cannot enter $2"
  sha=$3
  # Not "$sha^": a root commit has no parent and the command would fail with
  # exit 128. git show --name-only works there too.
  if "${GITSAFE[@]}" rev-parse -q --verify "$sha^2" >/dev/null 2>&1; then
    "${GITSAFE[@]}" -c core.quotepath=false diff "${DIFFSAFE[@]}" --name-only "$sha^1" "$sha" || die "git diff failed"
  else
    "${GITSAFE[@]}" -c core.quotepath=false show "${DIFFSAFE[@]}" --name-only --format= "$sha" || die "git show failed"
  fi
  exit 0
fi

# ------------------------------------------------------------ snapshot

[ $# -eq 1 ] || die "usage: $0 <repo>  |  $0 --files <repo> <sha>"
REPO=$1
[ -d "$REPO" ] || die "directory does not exist: $REPO"
cd "$REPO" || die "cannot enter $REPO"      # a failed cd would snapshot the WRONG repo
"${GITSAFE[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $REPO"

# --- Gate 1: executable configuration that arrived WITH the repository -------
# Only --local. The boundary is the origin of the configuration, not its
# presence: --local is .git/config, which travels with a directory somebody
# sent you; the global config is your own machine setup. Without that
# distinction the gate stops every repository on a machine that has git-lfs
# installed, because lfs declares filter.lfs.clean/process globally.
#
# Key NAMES are printed, never values: a command in a config may carry a token,
# and the "never print secret values" rule applies here too.
#
# --includes is load-bearing. Without it this lookup reads .git/config alone,
# while every ordinary git command expands include.path -- so a repository can
# park `filter.evil.clean` in .git/extra.cfg, include it from .git/config, and
# the gate sees nothing while `git add` runs the command. Reproduced: the marker
# file was created and the snapshot exited 0. --includes only expands directives
# found inside the local file, so a machine-global git-lfs filter still does not
# reach this check.
if FLT=$("${GITSAFE[@]}" config --local --includes --name-only --get-regexp \
         '^(filter\..*\.(clean|process|smudge)|diff\..*\.(textconv|command))$' 2>/dev/null); then
  say "STOPPED: the repository's LOCAL config declares executable drivers:"
  printf '%s\n' "$FLT" >&2
  say "git add/show/diff would run them as commands. This configuration arrived"
  say "with the directory; it is not yours. Read .git/config and decide deliberately."
  say "Values are deliberately not printed -- they may contain a token."
  exit 2
fi
for k in core.fsmonitor core.hooksPath core.sshCommand core.pager core.editor \
         gpg.program gpg.openpgp.program sequence.editor uploadpack.packObjectsHook; do
  if "${GITSAFE[@]}" config --local --includes --get "$k" >/dev/null 2>&1; then
    say "STOPPED: the local config sets $k -- an executable command from a foreign directory."
    say "The value is not printed. Read .git/config yourself."
    exit 2
  fi
done

say '--- what goes into the snapshot ---'
"${GITSAFE[@]}" status --short >&2 || die "git status failed"

# --- Gate 2: secrets by file name -------------------------------------------
# All names that will enter the snapshot: git add -A takes tracked, staged and
# untracked alike. The gate is deliberately conservative -- a file deleted only
# in the working tree will not enter the snapshot but still appears in
# ls-files and will stop the call. A needless stop is cheaper than a leak.
TRACKED=$("${GITSAFE[@]}" -c core.quotepath=false ls-files) || die "git ls-files failed"
UNTRACKED=$("${GITSAFE[@]}" -c core.quotepath=false ls-files --others --exclude-standard) \
  || die "git ls-files --others failed"
NAMES=$(printf '%s\n%s\n' "$TRACKED" "$UNTRACKED")

# core.quotepath=false stops git quoting non-ASCII, but a name containing a
# control character is ALWAYS C-quoted and wrapped in double quotes. That turns
# `.env<LF>x` into a line where a backslash follows `.env`, which the pattern
# below does not match -- the name gate would let it through. Rather than parse
# the escaping, refuse: a filename with a control character in it is not
# something a normal project has, and it cannot be reported honestly either.
QUOTED=$(printf '%s\n' "$NAMES" | grep -c '^"' || true)
if [ "${QUOTED:-0}" -gt 0 ]; then
  say "STOPPED: $QUOTED file name(s) contain a control character (git had to quote them)."
  say "The name gate cannot read such names reliably, so this call is refused."
  say "Rename them, or move them out of the repository."
  exit 2
fi

NAME_RE='\.env($|[.~/_-])|(^|/)\.?env\.(local|prod|production|dev|staging)|secret|credential|password|passwd|api[-_]?key|\.pem($|[.])|\.p12($|[.])|\.pfx($|[.])|\.key($|[.])|\.jks($|[.])|\.kdbx($|[.])|\.ppk($|[.])|\.session($|[.])|id_rsa|id_dsa|id_ecdsa|id_ed25519|(^|/)\.netrc|(^|/)\.npmrc|(^|/)kubeconfig|(^|/)\.pgpass|token'

# fail-closed: grep exit 1 means "no match", exit >1 means FAILURE. A form that
# cannot tell them apart opens the gate when grep itself breaks.
# LC_ALL=C: case folding is locale-dependent. In a Turkish locale `I` and `i`
# are not a pair, so `API_KEY` need not match a lower-case `api[-_]?key`. The
# patterns are ASCII, so byte semantics are exactly what is wanted here.
HITS=$(printf '%s\n' "$NAMES" | LC_ALL=C grep -Ei "$NAME_RE"); grc=$?
if [ "$grc" -eq 0 ]; then
  say "STOPPED: files with suspicious names would enter the snapshot:"
  printf '%s\n' "$HITS" | head -20 >&2
  say "Deal with them first. If this is a false positive, move the file or narrow the list."
  exit 2
elif [ "$grc" -gt 1 ]; then
  die "name gate could not run (grep returned $grc) -- call stopped" 2
fi

ST=$("${GITSAFE[@]}" status --porcelain) || die "git status --porcelain failed"

if ! "${GITSAFE[@]}" rev-parse --verify -q HEAD >/dev/null; then
  die "the repository has no commits -- there is no --commit form; handle this separately"
elif [ -z "$ST" ]; then
  BASE=$("${GITSAFE[@]}" rev-parse HEAD) || die "git rev-parse HEAD failed"
else
  # The snapshot is assembled in a SEPARATE index: `git add -A` against the
  # working index would destroy the staged/unstaged boundary, and the next
  # commit would pick up more than intended.
  IDX=$(compat_mktemp) || die "mktemp failed"
  GIT_INDEX_FILE="$IDX" "${GITSAFE[@]}" read-tree HEAD &&
  GIT_INDEX_FILE="$IDX" "${GITSAFE[@]}" add -A &&
  TREE=$(GIT_INDEX_FILE="$IDX" "${GITSAFE[@]}" write-tree) &&
  # commit-tree -p HEAD gives ONE parent. `git stash create` gives two, and
  # `git show` on a merge prints an empty patch -- a silent, convincing failure.
  BASE=$(GIT_INDEX_FILE="$IDX" "${GITSAFE[@]}" commit-tree "$TREE" -p HEAD -m "review snapshot")
  st=$?
  rm -f "$IDX"
  { [ $st -eq 0 ] && [ -n "$BASE" ]; } || die "snapshot could not be assembled"
fi

MERGE=no
"${GITSAFE[@]}" rev-parse -q --verify "$BASE^2" >/dev/null 2>&1 && MERGE=yes
if [ "$MERGE" = yes ]; then
  say 'NOTE: BASE is a MERGE commit -- git show prints a collapsed patch.'
  say '      Check coverage with --files (it switches to the diff form itself).'
fi

if [ "$MERGE" = yes ]; then
  PATCH=$("${GITSAFE[@]}" diff "${DIFFSAFE[@]}" "$BASE^1" "$BASE") || die "could not obtain the snapshot patch"
  FLIST=$("${GITSAFE[@]}" -c core.quotepath=false diff "${DIFFSAFE[@]}" --name-only "$BASE^1" "$BASE") || die "could not list snapshot files"
else
  PATCH=$("${GITSAFE[@]}" show "${DIFFSAFE[@]}" --format= "$BASE") || die "could not obtain the snapshot patch"
  FLIST=$("${GITSAFE[@]}" -c core.quotepath=false show "${DIFFSAFE[@]}" --name-only --format= "$BASE") || die "could not list snapshot files"
fi

# --- Gate 3: secrets by patch CONTENT ---------------------------------------
# The name gate cannot see a secret under a neutral name (config.yml,
# handler.py). Classes are tested one at a time so the report can NAME the kind
# of match without ever extracting the matched text.
SECRET_NAMES=(
  "private key (PEM/OpenSSH/PGP)" "AWS access key" "GitHub token"
  "GitLab token" "Slack token" "OpenAI/Stripe key" "Google API key"
  "JWT" "Docker Hub token" "long secret assignment"
)
Q=\'
SECRET_RES=(
  '-----BEGIN( [A-Z]+)* PRIVATE KEY( BLOCK)?-----'
  '(AKIA|ASIA)[0-9A-Z]{16}'
  '(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})'
  'glpat-[A-Za-z0-9_-]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  '(sk-[A-Za-z0-9_-]{20,}|(sk|rk)_live_[A-Za-z0-9]{20,})'
  'AIza[0-9A-Za-z_-]{35}'
  'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'
  'dckr_pat_[A-Za-z0-9_-]{20,}'
  "(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)[\"$Q]?[[:space:]]*[:=][[:space:]]*[\"$Q]?[A-Za-z0-9/+._-]{16,}"
)

# ADDED lines only: removing a secret from a file should not stop the call.
# The pipeline is split into steps with separate exit-code checks: in the form
# `A | grep | grep` a failure of the FIRST grep is lost if the second returns 1,
# the pipeline reports 1 -- "no match" -- and the gate opens.
ADDED=$(printf '%s\n' "$PATCH" | grep -nE '^\+'); arc=$?
[ "$arc" -gt 1 ] && die "content scanner: selecting added lines failed (grep returned $arc)" 2

FOUND=''
for i in "${!SECRET_RES[@]}"; do
  HIT=$(printf '%s\n' "$ADDED" | LC_ALL=C grep -Ei -- "${SECRET_RES[$i]}"); src=$?
  [ "$src" -gt 1 ] && die "content scanner: check '${SECRET_NAMES[$i]}' failed (grep returned $src)" 2
  LN=$(printf '%s\n' "$HIT" | grep -o '^[0-9]*' | head -5 | tr '\n' ' ')
  [ -n "$LN" ] && FOUND="$FOUND
  ${SECRET_NAMES[$i]} -- patch lines: $LN"
done

if [ -n "$FOUND" ]; then
  say 'STOPPED: added lines in the snapshot look like a secret.'
  printf '%s\n' "$FOUND" >&2
  say ''
  say 'Only the KIND and line numbers are printed -- not one character of any value.'
  say "Inspect it yourself: git show --no-textconv --no-color $BASE"
  say 'If this is a false positive, move the file out of the snapshot or narrow the pattern.'
  exit 2
fi

# --- Binary content the scanner cannot see -----------------------------------
# git prints "Binary files a/x and b/x differ" instead of the bytes, so gate 3
# is structurally blind to a secret inside a binary. This does not stop the call
# -- a repository committing an image is ordinary and blocking it would make the
# tool unusable -- but the blindness is NAMED rather than left silent.
# Take the b/ side, not the a/ side: for a NEWLY ADDED binary git prints
# "Binary files /dev/null and b/x.bin differ", and stripping the a/ prefix left
# the note pointing at /dev/null instead of the file nobody scanned.
BINFILES=$(printf '%s\n' "$PATCH" | grep -E '^Binary files ' \
  | sed 's/^Binary files .* and b\///; s/ differ$//' | grep -v '^/dev/null$')
if [ -n "$BINFILES" ]; then
  say 'NOTE: the snapshot contains binary files. Their contents were NOT scanned'
  say '      for secrets -- git shows only "Binary files differ", never the bytes:'
  printf '%s\n' "$BINFILES" | head -10 | sed 's/^/        /' >&2
fi

# --- Volume ------------------------------------------------------------------
# An oversized patch produces a partial review that looks complete.
PLINES=$(printf '%s\n' "$PATCH" | wc -l | tr -d '[:space:]')
PFILES=$(printf '%s' "$FLIST" | grep -c . || true)
say "snapshot size: $PLINES patch lines, $PFILES files"
if [ "$PLINES" -gt 2000 ]; then
  say 'WARNING: PATCH IS LARGER THAN 2000 LINES.'
  say '         A non-empty verdict on this much code is easy to mistake for a full'
  say '         review even though part of the code never reached the model. Split it'
  say '         by meaning -- by subsystem or by file -- and make several calls.'
  say '         Mechanical chunking is worse: it severs cross-file context.'
fi

printf 'BASE=%s\n' "$BASE"
printf 'MERGE=%s\n' "$MERGE"
printf 'LINES=%s\n' "$PLINES"
printf 'FILES=%s\n' "$PFILES"
