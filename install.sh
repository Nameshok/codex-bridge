#!/usr/bin/env bash
# install.sh -- set up codex-bridge for Claude Code.
#
#   bash install.sh              install, then verify
#   bash install.sh --check      report what is missing, change nothing
#   bash install.sh --uninstall  remove the skill (your Codex config is kept)
#
# What it does, and nothing more:
#   1. verifies prerequisites (bash, git, node, codex, a Codex login)
#   2. creates ~/.codex/AGENTS.md          if absent  -- the reviewer instruction
#   3. creates ~/.codex/claude-safe.config.toml if absent -- the write-safety profile
#   4. adds an [agents] section to ~/.codex/config.toml if absent -- enables fanout
#   5. copies the skill to ~/.claude/skills/codex-bridge/
#   6. runs bin/check-all.sh
#
# ~/.codex above is the default. CODEX_HOME overrides it, and the runner and the
# health check resolve the same variable, so the three cannot disagree about
# where the profile lives. It has to be an absolute path.
#
# It never overwrites a Codex configuration file you already have. AGENTS.md and
# the profile are created only when absent, and an AGENTS.md missing the reviewer
# instruction is reported, not edited, unless you say yes. Step 4 is the one
# exception and the only file this script changes on its own: a config.toml
# without an [agents] section gets one appended, because the fanout route needs
# it and silently stops fanning out without it. Re-running is safe.
#
# The one thing it does replace is a previous install of THIS skill: the old
# directory is moved to ~/.claude/codex-bridge.previous, and an older backup
# already sitting there is discarded once the new install succeeds. If you keep
# local edits inside the skill directory, copy them out before re-running.

set -uo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_SRC="$SRC/skill"
SKILL_DST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/codex-bridge"
# Deliberately not under the skills directory -- see the backup step below.
BACKUP_DST="$HOME/.claude/codex-bridge.previous"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
MODE=${1:-install}

RED=''; GRN=''; YLW=''; OFF=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; OFF=$'\033[0m'
fi
ok()   { printf '  %sok%s %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '  %s!%s %s\n' "$YLW" "$OFF" "$1"; }
bad()  { printf '  %sx%s %s\n' "$RED" "$OFF" "$1"; MISSING=$((MISSING+1)); }
step() { printf '\n== %s ==\n' "$1"; }
MISSING=0
NEED_LOGIN=0

# ---------------------------------------------------------------- uninstall

if [ "$MODE" = --uninstall ]; then
  step "Uninstall"
  if [ -d "$SKILL_DST" ]; then
    rm -rf "$SKILL_DST" && ok "removed $SKILL_DST"
  else ok "nothing to remove at $SKILL_DST"; fi
  if [ -d "$BACKUP_DST" ]; then
    rm -rf "$BACKUP_DST" && ok "removed the previous-install backup $BACKUP_DST"
  fi
  printf '\nYour Codex configuration in %s was left untouched on purpose:\n' "$CODEX_HOME"
  printf 'AGENTS.md, claude-safe.config.toml and config.toml may be used by other tools.\n'
  exit 0
fi

# ---------------------------------------------------------------- codex home

# Deliberately AFTER the uninstall branch. Removing an installed copy must not
# depend on the state of the source tree: an earlier version of this check ran
# up here and made `--uninstall` fail on an incomplete checkout, leaving the
# installed skill in place with nothing to remove it.
#
# Refused, not resolved: a relative value would put the profile next to whatever
# directory this script was started from, while the runner would look for it next
# to the directory ITS caller was started from. Codex resolves it once more, on
# its own. Three answers to one question is worse than no answer. The test comes
# from the kit being installed, so the installer and the installed runner cannot
# disagree about what "absolute" means -- it is platform-dependent, and a
# drive-letter path is absolute only where drive letters exist.
if [ -f "$SKILL_SRC/bin/compat.sh" ]; then
  # shellcheck source=skill/bin/compat.sh
  . "$SKILL_SRC/bin/compat.sh"
else
  printf 'cannot find %s -- run this script from a complete checkout\n' "$SKILL_SRC/bin/compat.sh" >&2
  exit 1
fi
compat_is_absolute "$CODEX_HOME" || {
  printf 'CODEX_HOME must be an absolute path (got "%s")\n' "$CODEX_HOME" >&2
  exit 1
}

# ---------------------------------------------------------------- prerequisites

step "Prerequisites"
for c in bash git node; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c -- $(command -v "$c")"
  else bad "$c is not installed"; fi
done

# Stock macOS still ships bash 3.2, and `#!/usr/bin/env bash` picks it up. The
# runner is written to work there, but the version is worth stating: if a future
# change reintroduces a bash 4 construct, this line is where it surfaces.
BASH_MAJOR=${BASH_VERSINFO[0]:-0}
if [ "$BASH_MAJOR" -ge 4 ]; then ok "bash $BASH_VERSION"
elif [ "$BASH_MAJOR" -eq 3 ]; then
  warn "bash $BASH_VERSION -- supported, but this is the 2007 version Apple still ships"
  warn "  if anything behaves oddly, 'brew install bash' and re-run"
else bad "bash $BASH_VERSION is too old"; fi

if command -v codex >/dev/null 2>&1; then
  CODEX_VER=$(codex --version 2>/dev/null || printf 'unknown')
  ok "codex -- $CODEX_VER"
  EXPECT=$(cat "$SKILL_SRC/bin/expected-codex-version.txt" 2>/dev/null || printf '')
  if [ -n "$EXPECT" ] && [ "$CODEX_VER" != "$EXPECT" ]; then
    warn "this project's behaviour notes were verified on $EXPECT"
    warn "  a different version is usually fine, but run bin/check-all.sh after installing"
  fi
  # Not being logged in is a warning, not a blocker: the files can be put in
  # place now and the login done afterwards. Refusing to install over it would
  # send people away with nothing.
  if codex login status 2>&1 | grep -qi 'logged in'; then ok "codex is logged in"
  else warn "codex is not logged in -- run 'codex login' before the first review"; NEED_LOGIN=1; fi
else
  bad "codex is not installed -- see https://developers.openai.com/codex"
fi

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  ok "timeout available"
else
  warn "no timeout(1) -- a built-in fallback will be used (macOS: brew install coreutils)"
fi

if [ "$MODE" = --check ]; then :; elif [ "$MISSING" -gt 0 ]; then
  printf '\n%sInstall stopped:%s %d prerequisite(s) missing.\n' "$RED" "$OFF" "$MISSING"
  exit 1
fi

# ---------------------------------------------------------------- codex config

step "Codex configuration ($CODEX_HOME)"
[ "$MODE" = --check ] || mkdir -p "$CODEX_HOME"

ANCHOR=$(cat "$SKILL_SRC/bin/agents-anchor.txt" 2>/dev/null || printf 'Look for what breaks')

# --- AGENTS.md ---------------------------------------------------------------
# This is what turns the reviewer into a skeptic. Without it the verdicts stay
# polite and agreeable, and nothing else in the output shows that anything is
# wrong -- which is why check-all greps for the anchor phrase rather than just
# checking that the file exists.
AGENTS="$CODEX_HOME/AGENTS.md"
if [ -f "$AGENTS" ]; then
  if grep -qF -- "$ANCHOR" "$AGENTS"; then
    ok "AGENTS.md already contains the reviewer instruction"
  else
    warn "AGENTS.md exists but has no reviewer instruction"
    warn "  it was NOT modified. Append this line yourself, or reviews will be toothless:"
    printf '\n      %s\n\n' "$ANCHOR"
    if [ "$MODE" != --check ]; then
      printf '  Append it now? [y/N] '; read -r a </dev/tty || a=n
      case $a in
        [yY]*) if printf '\n%s\n' "$ANCHOR" >> "$AGENTS"; then ok "appended"
               else bad "could not write to $AGENTS"; fi ;;
        *)     warn "left unchanged" ;;
      esac
    fi
  fi
else
  if [ "$MODE" = --check ]; then bad "AGENTS.md is missing"
  else
    # `if ! cat > file <<EOF` checks the WRITE, not just the result. Testing
    # only `-s` afterwards accepted a heredoc truncated by a full disk: the file
    # is non-empty, so it passed, and the reviewer instruction was half there.
    if ! cat > "$AGENTS" <<EOF
# Reviewer instructions

$ANCHOR. Do not flatter and do not soften.

When you are asked to review something -- code, a plan, a document, a estimate --
your job is to find what will fail, not to praise what works. State findings
plainly with a precise pointer (file:line, or page/cell/section where there are
no lines), a severity, and whether the finding is confirmed or a hypothesis.

If you have no objections, say so briefly. An invented finding costs more than
a missed one.

Report what you could not check: commands the environment refused to run,
files you did not read, and anything you assumed rather than verified.
EOF
    then
      bad "could not write $AGENTS -- check permissions and free space on $CODEX_HOME"
    elif ! grep -qF -- "$ANCHOR" "$AGENTS" 2>/dev/null; then
      bad "$AGENTS was written but is incomplete -- the reviewer instruction is missing"
    else
      ok "created AGENTS.md"
    fi
  fi
fi

# --- claude-safe profile -----------------------------------------------------
# A Codex "V2 profile" IS the file $CODEX_HOME/<name>.config.toml. This one is
# a safety net for the image routes: if the -s flag is ever lost, the profile
# drops the run to read-only and the failure is loud instead of a silent write
# over your whole project root.
PROFILE="$CODEX_HOME/claude-safe.config.toml"
if [ -f "$PROFILE" ]; then
  ok "claude-safe profile already present"
elif [ "$MODE" = --check ]; then
  bad "claude-safe.config.toml is missing (image routes will refuse to run)"
else
  if ! cat > "$PROFILE" <<'EOF'
# claude-safe -- profile used by codex-bridge for routes that write files.
#
# It exists as a safety net, not as the primary control. The primary control is
# the explicit -s flag the runner passes. If that flag is ever lost, this
# profile drops the run to read-only, so image generation fails loudly instead
# of quietly gaining write access to a whole project root.
#
# Note: a profile has NO effect under --ignore-user-config. The runner refuses
# any route that combines workspace-write with that flag, so this cannot
# silently become decoration.

approval_policy = "never"
sandbox_mode    = "read-only"
EOF
  then
    bad "could not write $PROFILE -- check permissions and free space on $CODEX_HOME"
  elif ! grep -q '^sandbox_mode' "$PROFILE" 2>/dev/null; then
    bad "$PROFILE was written but is incomplete"
  else
    ok "created claude-safe profile"
  fi
fi

# --- [agents] ----------------------------------------------------------------
# Only the fanout route needs this. Its absence is not fatal: fanout would run
# but silently behave like an ordinary review, which is worse than failing, so
# check-all reports it.
CFG="$CODEX_HOME/config.toml"
if [ -f "$CFG" ] && grep -q '^\[agents\]' "$CFG"; then
  ok "[agents] already present (fanout route usable)"
elif [ "$MODE" = --check ]; then
  warn "no [agents] section -- the fanout route will not fan out"
else
  # max_parallel is the LAST line written, so grepping for it proves the whole
  # block landed. Checking for the [agents] header alone accepted an append that
  # died immediately after it.
  if {
    printf '\n# --- added by codex-bridge install.sh ---\n'
    printf '# Enables the fanout route: several subagents review in parallel.\n'
    printf '# Remove this section if you do not want subagents.\n'
    printf '[agents]\n'
    printf 'max_parallel = 3\n'
  } >> "$CFG" && grep -q '^max_parallel' "$CFG" 2>/dev/null; then
    ok "appended an [agents] section to config.toml"
  else
    bad "could not write $CFG -- check permissions and free space on $CODEX_HOME"
  fi
fi

# ---------------------------------------------------------------- skill

step "Skill"
if [ "$MODE" = --check ]; then
  [ -d "$SKILL_DST" ] && ok "installed at $SKILL_DST" || bad "not installed"
else
  # A write failure while setting up the Codex configuration means the install
  # did not do what it printed. Stop here with the documented "install failed"
  # code rather than carrying on and failing later somewhere unrelated.
  if [ "$MISSING" -gt 0 ]; then
    printf '\n%sInstall stopped:%s %d step(s) failed above.\n' "$RED" "$OFF" "$MISSING"
    exit 1
  fi

  mkdir -p "$(dirname "$SKILL_DST")"
  RESTORE=''
  if [ -d "$SKILL_DST" ]; then
    # The backup goes OUTSIDE the skills directory, and there is exactly one of
    # them. A copy left beside the original is itself a valid skill directory:
    # Claude Code would load it too, and two skills would claim the same name.
    #
    # The PREVIOUS backup is moved aside rather than deleted outright, and is
    # only removed once the new install is in place. Deleting it first meant a
    # failure halfway through left the user with neither their installation nor
    # their backup.
    mkdir -p "$(dirname "$BACKUP_DST")"
    OLDBK=''
    if [ -d "$BACKUP_DST" ]; then
      OLDBK="$BACKUP_DST.superseded.$$"
      mv "$BACKUP_DST" "$OLDBK" || { printf 'could not set the old backup aside\n' >&2; exit 1; }
    fi
    if mv "$SKILL_DST" "$BACKUP_DST"; then
      RESTORE="$BACKUP_DST"
      ok "previous install kept at $BACKUP_DST"
    else
      [ -n "$OLDBK" ] && mv "$OLDBK" "$BACKUP_DST"
      printf 'could not move the previous install aside\n' >&2; exit 1
    fi
  fi
  mkdir -p "$SKILL_DST"
  if ! cp -R "$SKILL_SRC/." "$SKILL_DST/"; then
    printf 'copy failed\n' >&2
    # Put the working installation back. Leaving an empty or half-copied skill
    # directory behind is worse than not having run the installer at all.
    if [ -n "$RESTORE" ]; then
      rm -rf "$SKILL_DST"
      if mv "$RESTORE" "$SKILL_DST"; then
        printf 'the previous installation was restored\n' >&2
        [ -n "${OLDBK:-}" ] && mv "$OLDBK" "$BACKUP_DST"
      else
        printf 'RESTORE FAILED -- your previous installation is at %s\n' "$RESTORE" >&2
      fi
    fi
    exit 1
  fi
  chmod +x "$SKILL_DST"/bin/*.sh 2>/dev/null
  [ -n "${OLDBK:-}" ] && rm -rf "$OLDBK"
  ok "installed to $SKILL_DST"
fi

# ---------------------------------------------------------------- verify

if [ "$MODE" = --check ]; then
  printf '\n'
  [ "$MISSING" -eq 0 ] && { printf '%sReady.%s Run: bash install.sh\n' "$GRN" "$OFF"; exit 0; }
  printf '%s%d item(s) missing.%s\n' "$RED" "$MISSING" "$OFF"; exit 1
fi

step "Verification"
# Exit codes are deliberate and distinct:
#   0  files installed AND the bridge is usable right now
#   2  files installed, but something still stands between you and a first call
#      (almost always: you have not logged in yet)
#   1  the install itself failed
bash "$SKILL_DST/bin/check-all.sh"; HEALTH=$?

printf '\n'
if [ "$HEALTH" -eq 0 ]; then
  printf '%sInstalled and ready.%s\n\n' "$GRN" "$OFF"
elif [ "$NEED_LOGIN" -eq 1 ]; then
  printf '%sInstalled -- one step left.%s\n\n' "$YLW" "$OFF"
  printf '  codex login\n\n'
  printf 'Then confirm with:\n  bash %s/bin/check-all.sh\n\n' "$SKILL_DST"
else
  printf '%sInstalled, but the health check found problems above.%s\n\n' "$YLW" "$OFF"
  printf 'Fix them, then re-run:\n  bash %s/bin/check-all.sh\n\n' "$SKILL_DST"
fi

cat <<EOF
The skill loads itself when a task calls for an independent review, a second
opinion, or a generated image -- you never invoke it by name.

Try it:   bash $SKILL_DST/bin/check-all.sh --live
Read:     $SKILL_DST/SKILL.md
EOF

[ "$HEALTH" -eq 0 ] && exit 0
[ "$NEED_LOGIN" -eq 1 ] && exit 2
exit 2
