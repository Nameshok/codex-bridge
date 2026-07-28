#!/usr/bin/env bash
# codex-run.sh -- the single entry point for calling Codex.
#
# Usage:  bash codex-run.sh <request-file>
#
# The request file is written by the agent with a file-writing tool (never
# through a shell) and contains "key=value" lines. No value ever reaches the
# shell as code: argv is built as an array and `eval` is not used anywhere.
#
# WHY A FILE AND NOT ARGUMENTS: the shell parses the calling command BEFORE this
# script starts. A path containing $(...) or backticks, pasted literally into
# that command, executes in the caller's shell, and a positional argument cannot
# undo it. So dangerous values must never appear on a command line at all.
#
# Exit codes:
#   0  verdict received, non-empty, contains more than whitespace
#   1  no verdict (Codex failed, timed out, or wrote nothing)
#   2  bad request, corrupt registry, or a gate stopped the call
#   3  route is background-only and confirm_background=yes was not given
#   9  dry run (CODEX_RUN_DRYRUN=1): argv printed, Codex not called
#
# STDOUT is exactly one line -- the path to the verdict file. Everything else,
# including the whole Codex transcript, goes to stderr. That is what makes
# `OUT=$(codex-run.sh req.conf)` work.

set -uo pipefail

BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_DIR=$(cd "$BIN_DIR/.." && pwd)
REGISTRY="$BIN_DIR/routes.conf"
LOG_DIR="$SKILL_DIR/var"
LOG="$LOG_DIR/calls.jsonl"

# shellcheck source=compat.sh
. "$BIN_DIR/compat.sh"

die()  { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-2}"; }
note() { printf '%s\n' "$1" >&2; }

[ -f "$REGISTRY" ] || die "route registry not found: $REGISTRY"
[ $# -eq 1 ] || die "expects exactly one argument -- the path to a request file"
REQ=$1
[ -f "$REQ" ] || die "request file not found: $REQ"

# ---------------------------------------------------------------- JSON

# Escaping for JSON. Five mandatory substitutions plus removal of the remaining
# C0 control characters; after this the string is a valid JSON string.
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# One JSONL line per printf: a write of under 4096 bytes in append mode is
# atomic, so concurrent calls cannot tear each other's lines.
log_event() {
  local ev=$1; shift
  mkdir -p "$LOG_DIR" 2>/dev/null
  local line
  line=$(printf '{"ts":"%s","event":"%s","call_id":"%s"' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$ev")" "$(json_escape "$CALL_ID")")
  while [ $# -ge 2 ]; do
    # Unquoted only for a real integer. A looser test let "--", "-" and "1-2"
    # through unquoted and produced invalid JSON.
    if [[ $2 =~ ^-?(0|[1-9][0-9]*)$ ]]; then
      line="$line,\"$(json_escape "$1")\":$2"
    else
      line="$line,\"$(json_escape "$1")\":\"$(json_escape "$2")\""
    fi
    shift 2
  done
  printf '%s}\n' "$line" >> "$LOG"
}

# ---------------------------------------------------------------- request

# Deliberately NOT an associative array. `declare -A` needs bash 4, and stock
# macOS still ships bash 3.2 -- the script would abort on its own first line of
# real work on a platform this project claims to support. `printf -v` and a
# seen-list give the same two properties (lookup by name, duplicate detection)
# on bash 3.2, and still without `eval`.
REQ_SEEN=':'
# An associative array starts empty; plain shell variables are inherited from
# the environment. Without this loop, REQ_confirm_background=yes in the
# environment satisfied the background gate, and REQ_route supplied a route the
# request file never mentioned -- verified, rc went from 3 to 9. Clearing them
# first is what makes the request file the only source of request fields.
for f in route dir prompt_file out_dir subject commit base session_id schema \
         ephemeral confirm_background; do
  unset "REQ_$f"
done
IMAGES=()
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno+1))
  line=${raw%$'\r'}                       # the file may use CRLF
  case $line in ''|'#'*) continue ;; esac
  case $line in *=*) ;; *) die "request line $lineno is not key=value: $line" ;; esac
  k=${line%%=*}
  v=${line#*=}
  k=${k%"${k##*[![:space:]]}"}
  k=${k#"${k%%[![:space:]]*}"}
  case $k in
    image) IMAGES+=("$v") ;;
    route|dir|prompt_file|out_dir|subject|commit|base|session_id|schema|ephemeral|confirm_background)
      case $REQ_SEEN in *":$k:"*) die "field '$k' given twice (line $lineno)" ;; esac
      REQ_SEEN="$REQ_SEEN$k:"
      printf -v "REQ_$k" '%s' "$v" ;;
    *) die "unknown request field '$k' (line $lineno)" ;;
  esac
done < "$REQ"

# ${!name} is indirect expansion, not eval: bash resolves the variable NAME held
# in $n and never parses $v as code.
get()      { local n="REQ_$1"; printf '%s' "${!n-}"; }
was_given() { case $REQ_SEEN in *":$1:"*) return 0 ;; esac; return 1; }

ROUTE=$(get route);     [ -n "$ROUTE" ]   || die "request is missing required field: route"
DIR=$(get dir);         [ -n "$DIR" ]     || die "request is missing required field: dir"
OUT_DIR=$(get out_dir); [ -n "$OUT_DIR" ] || die "request is missing required field: out_dir"
SUBJECT=$(get subject); [ -n "$SUBJECT" ] || die "request is missing required field: subject (what is under review -- it goes in the log)"

[ -d "$DIR" ]     || die "dir does not exist: $DIR"
[ -d "$OUT_DIR" ] || die "out_dir does not exist: $OUT_DIR"

# ---------------------------------------------------------------- registry

# The registry is parsed as a SCHEMA, not as a set of hints. A corrupt registry
# must fail the call rather than silently change its behaviour: otherwise a typo
# like `config: ignroe` would quietly mean the base config, and
# `sandbox: danger-full-access` would go straight into -s.
R_model=''; R_effort=''; R_config=''; R_profile=''; R_sandbox=''
R_form='';  R_timeout=''; R_background=''; R_allows=''; R_purpose=''
found=0; in_block=0; regline=0; REG_SEEN=':'
while IFS= read -r raw || [ -n "$raw" ]; do
  regline=$((regline+1))
  line=${raw%$'\r'}
  case $line in ''|'#'*) in_block=0; continue ;; esac
  case $line in *': '*|*':') ;; *) die "registry line $regline is not 'key: value'" ;; esac
  key=${line%%:*}; val=${line#*: }; [ "$line" = "$key:" ] && val=''
  if [ "$key" = route ]; then
    if [ "$val" = "$ROUTE" ]; then
      [ $found -eq 1 ] && die "registry: route '$ROUTE' declared twice (line $regline)"
      found=1; in_block=1
      # Reset is mandatory: without it the next block would inherit fields.
      R_model=''; R_effort=''; R_config=''; R_profile=''; R_sandbox=''
      R_form=''; R_timeout=''; R_background=''; R_allows=''; R_purpose=''
      REG_SEEN=':'
    else in_block=0; fi
    continue
  fi
  [ $in_block -eq 1 ] || continue
  # A repeated field inside one route block is refused, not last-wins. A second
  # `allows:` line silently widening the first one is a privilege change that
  # would leave no trace anywhere.
  case $REG_SEEN in *":$key:"*) die "registry line $regline: field '$key' repeated in route '$ROUTE'" ;; esac
  REG_SEEN="$REG_SEEN$key:"
  case $key in
    model) R_model=$val ;;       effort) R_effort=$val ;;
    config) R_config=$val ;;     profile) R_profile=$val ;;
    sandbox) R_sandbox=$val ;;   form) R_form=$val ;;
    timeout) R_timeout=$val ;;   background) R_background=$val ;;
    allows) R_allows=$val ;;     purpose) R_purpose=$val ;;
    *) die "registry line $regline: unknown field '$key' in route '$ROUTE'" ;;
  esac
done < "$REGISTRY"

if [ $found -eq 0 ]; then
  note "Unknown route: $ROUTE"
  note "Known routes:"
  grep '^route: ' "$REGISTRY" | sed 's/^route: /  /' >&2
  exit 2
fi

# Indirect expansion ${!name} rather than eval: eval would be safe here (the
# field list is fixed), but then the header claim "eval is not used anywhere"
# would be false -- and prose drifting from mechanism is the exact failure this
# whole design exists to prevent.
for f in model effort config profile sandbox form timeout background purpose; do
  name="R_$f"
  [ -n "${!name}" ] || die "route '$ROUTE' is incomplete: registry has no '$f'"
done
grep -q "^allows:" <(awk -v r="$ROUTE" '$0=="route: "r{p=1;next} /^route: /{p=0} p' "$REGISTRY") \
  || die "route '$ROUTE' is incomplete: no 'allows' field (an empty value is fine, a missing line is not)"

# Values come only from enums. Otherwise "no silent defaults" would be a lie.
enum_ok() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }
enum_ok "$R_config"  'ignore,base'                   || die "registry: config='$R_config' -- allowed: ignore|base"
enum_ok "$R_sandbox" 'read-only,workspace-write'     || die "registry: sandbox='$R_sandbox' -- allowed: read-only|workspace-write (danger-full-access is forbidden)"
enum_ok "$R_form"    'exec,review'                   || die "registry: form='$R_form' -- allowed: exec|review"
enum_ok "$R_background" 'yes,no'                     || die "registry: background='$R_background' -- allowed: yes|no"
enum_ok "$R_effort"  'low,medium,high,xhigh,max,ultra' || die "registry: effort='$R_effort' is not a valid effort"
enum_ok "$R_model"   'gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-luna' || die "registry: model='$R_model' is outside the supported family"
case $R_timeout in ''|*[!0-9]*) die "registry: timeout='$R_timeout' must be a whole number of seconds" ;; esac
case $R_profile in none|claude-safe) ;; *) die "registry: profile='$R_profile' -- allowed: none|claude-safe" ;; esac
if [ "$R_sandbox" = workspace-write ]; then
  [ "$R_config" = base ] || die "registry: workspace-write is unreachable under config=ignore (the sandbox silently degrades)"
  [ "$R_profile" = claude-safe ] || die "registry: workspace-write without the safety profile is forbidden"
fi

# ---------------------------------------------------------------- route fields

allowed_field() { case ",$R_allows," in *",$1,"*) return 0 ;; esac; return 1; }
for f in commit base session_id schema ephemeral confirm_background; do
  was_given "$f" && ! allowed_field "$f" && \
    die "route '$ROUTE' does not accept field '$f' (allowed: ${R_allows:-none})"
done

# Switch fields are checked against an enumeration. Without this, `ephemeral=yees`
# silently meant "no": the value is compared against `yes` further down, so a typo
# quietly turned the session persistent instead of stopping the call. `was_given`
# rather than a non-empty test on purpose -- an explicitly empty `ephemeral=` is a
# malformed value, not an omission, and letting it through restores the same
# silent default through the back door.
for f in ephemeral confirm_background; do
  was_given "$f" || continue
  case $(get "$f") in
    yes|no) ;;
    *) die "field '$f' takes only yes or no, got '$(get "$f")'" ;;
  esac
done
if [ ${#IMAGES[@]} -gt 0 ] && ! allowed_field image; then
  die "route '$ROUTE' does not accept field 'image' (allowed: ${R_allows:-none})"
fi

PROMPT_FILE=$(get prompt_file)
if [ "$R_form" = review ]; then
  [ -z "$PROMPT_FILE" ] || die "route '$ROUTE' is the built-in reviewer: it accepts no prompt at all (incompatible with --commit/--base)"
  if [ -n "$(get commit)" ] && [ -n "$(get base)" ]; then
    die "route '$ROUTE': commit and base are mutually exclusive -- pick one"
  fi
  [ -n "$(get commit)$(get base)" ] \
    || die "route '$ROUTE' needs commit (SHA of a frozen snapshot) or base (branch name)"
else
  [ -n "$PROMPT_FILE" ] || die "route '$ROUTE' needs a prompt_file"
  [ -s "$PROMPT_FILE" ] || die "prompt file is empty or missing: $PROMPT_FILE"
fi
[ -n "$(get schema)" ] && { [ -s "$(get schema)" ] || die "schema file is empty or missing: $(get schema)"; }
for img in ${IMAGES[@]+"${IMAGES[@]}"}; do
  [ -s "$img" ] || die "image file is empty or missing: $img"
done

# session_id must be a strict UUID. Otherwise a value like `--last` would land
# after `resume` as a CLI OPTION and continue somebody else's session.
SID=$(get session_id)
if [ -n "$SID" ]; then
  case $SID in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
    *) die "session_id='$SID' is not a UUID. Take the id from the header of the run you mean; --last and thread names are refused" ;;
  esac
fi

# commit must be a full 40-character SHA. The docs promise "a frozen snapshot",
# and HEAD, a branch name or an abbreviated SHA is a moving target.
CMT=$(get commit)
if [ -n "$CMT" ]; then
  case $CMT in *[!0-9a-f]*) die "commit='$CMT' is not a full lowercase SHA. Use the value printed by codex-snapshot.sh" ;; esac
  [ ${#CMT} -eq 40 ] || die "commit='$CMT' is ${#CMT} characters, a full SHA is 40"
fi

# Write boundary: -o writes the file regardless of the sandbox, so out_dir
# inside the working root would mean writing into the material under review.
ABS_DIR=$(compat_realpath "$DIR"); ABS_OUT=$(compat_realpath "$OUT_DIR")
case "$ABS_OUT/" in
  "$ABS_DIR"/*) die "out_dir is inside dir: the verdict would be written into the material under review. Use a scratch directory outside the project" ;;
esac

# ---------------------------------------------------------------- background

if [ "$R_background" = yes ] && [ "$(get confirm_background)" != yes ]; then
  note "Route '$ROUTE' runs with a ${R_timeout}s timeout, which is longer than a"
  note "foreground call should block for. A child process cannot put itself in the"
  note "background on the caller's behalf."
  note ""
  note "Start this call in the background and add this line to the request file:"
  note "  confirm_background=yes"
  exit 3
fi

# ---------------------------------------------------------------- target dir
# Checked on EVERY call, not once per session: the working directory changes,
# and with it both config precedence and the independence of the verdict.

# pwd -P gives the physical path. With a logical one, a symlink or junction
# inside $HOME pointing outside it would fool the walk boundary.
HOME_ABS=$(compat_realpath "$HOME")

# A project-level .codex/config.toml is a STOP, not a warning: it is not
# disabled by --ignore-user-config and can declare an MCP server with an
# arbitrary command, which starts together with the client. Codex assembles
# project layers from the project root down, so parents must be checked too.
# The walk stops at $HOME and never treats ~/.codex/config.toml as a project
# config -- that one is the user's own.
FOUND_PROJECT_CONFIG=''
probe=$ABS_DIR
while :; do
  [ "$probe" = "$HOME_ABS" ] && break
  [ -f "$probe/.codex/config.toml" ] && FOUND_PROJECT_CONFIG="$FOUND_PROJECT_CONFIG $probe/.codex/config.toml"
  parent=$(dirname "$probe"); [ "$parent" = "$probe" ] && break; probe=$parent
done
if [ -n "$FOUND_PROJECT_CONFIG" ]; then
  note "STOPPED: a project-level Codex config was found:$FOUND_PROJECT_CONFIG"
  note "It outranks the profile, is not disabled by --ignore-user-config, and can"
  note "declare an MCP server with an arbitrary command. Read it yourself and decide"
  note "deliberately; this call will not run blind."
  exit 2
fi

WARN_AGENTS=''
probe=$ABS_DIR
while :; do
  [ -f "$probe/AGENTS.md" ] && WARN_AGENTS="$WARN_AGENTS $probe/AGENTS.md"
  [ "$probe" = "$HOME_ABS" ] && break
  parent=$(dirname "$probe"); [ "$parent" = "$probe" ] && break; probe=$parent
done
if [ -n "$WARN_AGENTS" ]; then
  note "NOTE: AGENTS.md found:$WARN_AGENTS"
  note "      It outranks the prompt. If it points Codex at your own notes, the"
  note "      independence of this review is PARTIAL -- say so out loud."
fi

# ---------------------------------------------------------------- argv

if [ "${CODEX_RUN_DRYRUN:-}" = 1 ]; then
  CALL_ID=DRYRUN                       # deterministic, so golden tests can compare
else
  CALL_ID=$(compat_call_id)
fi
OUT="$OUT_DIR/codex-$ROUTE-$CALL_ID.md"

argv=(codex exec)
[ "$R_config" = ignore ] && argv+=(--ignore-user-config)
[ "$R_profile" != none ] && argv+=(-p "$R_profile")
argv+=(-s "$R_sandbox" --skip-git-repo-check)
argv+=(-m "$R_model" -c "model_reasoning_effort=\"$R_effort\"")
argv+=(-C "$DIR" -o "$OUT")
[ -n "$(get schema)" ] && argv+=(--output-schema "$(get schema)")
[ "$(get ephemeral)" = yes ] && argv+=(--ephemeral)
# --image=FILE, not -i FILE: the variadic -i can swallow the next argument.
for img in ${IMAGES[@]+"${IMAGES[@]}"}; do argv+=("--image=$img"); done

if [ "$R_form" = review ]; then
  argv+=(review)
  if [ -n "$CMT" ]; then argv+=(--commit "$CMT")
  else                   argv+=(--base   "$(get base)"); fi
  STDIN_SRC=/dev/null
else
  [ -n "$SID" ] && argv+=(resume "$SID")
  argv+=(-)                             # prompt from stdin
  STDIN_SRC=$PROMPT_FILE
fi

# ---------------------------------------------------------------- dry run
# Exit 9, deliberately not 0: the contract "0 means a verdict was received"
# must not break because an environment variable leaked into the environment.

if [ "${CODEX_RUN_DRYRUN:-}" = 1 ]; then
  printf 'STDIN<%s\n' "$STDIN_SRC"
  printf '%s\n' "${argv[@]}"
  exit 9
fi

# ---------------------------------------------------------------- preflight
# Inside the runner rather than a separate script: a separate step gets
# forgotten, this one cannot be. The global part is cached for 12 hours; the
# target-directory checks above are per-call and are never cached.

EXPECT_VERSION_FILE="$BIN_DIR/expected-codex-version.txt"
EXPECT_VERSION=$(cat "$EXPECT_VERSION_FILE" 2>/dev/null || printf '')

preflight() {
  local mark="$LOG_DIR/preflight.ok" age=0 now
  now=$(date +%s)
  if [ -f "$mark" ]; then
    age=$(( now - $(compat_mtime "$mark") ))
    [ "$age" -lt 43200 ] && grep -qxF -- "${EXPECT_VERSION:-__none__}" "$mark" 2>/dev/null && return 0
  fi
  command -v codex >/dev/null 2>&1 || die "codex is not in PATH -- there is no bridge. Say so instead of inventing a verdict." 1
  local ver; ver=$(codex --version 2>/dev/null) || die "codex --version failed -- there is no bridge" 1
  if [ -n "$EXPECT_VERSION" ] && [ "$ver" != "$EXPECT_VERSION" ]; then
    note "WARNING: Codex version drift. Expected '$EXPECT_VERSION', got '$ver'."
    note "         Flag behaviour is no longer known-verified: run bin/test-routes.sh"
    note "         and bin/test-snapshot.sh, re-check the CLI help, then update"
    note "         bin/expected-codex-version.txt."
  fi
  # 2>&1 is required: `codex login status` prints to STDERR and exits 0.
  codex login status 2>&1 | grep -qi 'logged in' \
    || die "codex is not logged in -- there is no bridge. Run 'codex login' in a terminal." 1
  # A hollowed-out AGENTS.md produces polite verdicts with no other symptom,
  # so grep for the anchor phrase rather than just checking the file exists.
  local anchor_file="$BIN_DIR/agents-anchor.txt" anchor
  anchor=$(cat "$anchor_file" 2>/dev/null || printf 'Look for what breaks')
  grep -qF -- "$anchor" "$HOME/.codex/AGENTS.md" 2>/dev/null \
    || die "~/.codex/AGENTS.md is missing or does not contain the skeptic instruction. Run install.sh." 1
  mkdir -p "$LOG_DIR" 2>/dev/null
  printf '%s\n' "$ver" > "$mark"
}
preflight

# The profile only matters to routes that write; its absence breaks image
# generation in a confusing way, so check it explicitly.
if [ "$R_profile" != none ]; then
  [ -f "$HOME/.codex/$R_profile.config.toml" ] \
    || die "missing profile ~/.codex/$R_profile.config.toml (a V2 profile IS that file). Run install.sh." 1
fi

# ---------------------------------------------------------------- run

log_event started route "$ROUTE" model "$R_model" effort "$R_effort" \
  sandbox "$R_sandbox" config "$R_config" form "$R_form" timeout "$R_timeout" \
  dir "$DIR" subject "$SUBJECT" out "$OUT" agents_md "${WARN_AGENTS# }"

note "-> $ROUTE: $R_model/$R_effort, sandbox=$R_sandbox, config=$R_config, timeout=${R_timeout}s"
note "   subject: $SUBJECT"

# The transcript is captured to a file and then sent to stderr in full.
# Captured, because the failure REASON is classified from it: "exit code 1"
# looks identical for an exhausted quota, a dropped login and a network fault,
# and those need different responses. Sent to stderr, because STDOUT must carry
# exactly one line -- the verdict path.
CAPTURE=$(compat_mktemp) || die "mktemp failed" 1
trap 'rm -f "$CAPTURE"' EXIT HUP INT TERM
compat_timeout "$R_timeout" "${argv[@]}" < "$STDIN_SRC" > "$CAPTURE" 2>&1
CODEX_RC=$?
cat "$CAPTURE" >&2

# Failure classification. Patterns are narrow and anchored: bare `401`, `429`,
# `login` or `certificate` also occur in the material under review, which is
# echoed into the transcript, and would override the real reason. If more than
# one class matches, that is ambiguity -- UNKNOWN is more honest than a wrong
# reason that sends you down the wrong path.
REASON=OK
if [ "$CODEX_RC" -eq 124 ]; then
  REASON=TIMEOUT
elif [ "$CODEX_RC" -ne 0 ]; then
  ERRLINES=$(grep -iE '^[[:space:]]*(error|fatal|panic)|stream error|ERROR ' "$CAPTURE" 2>/dev/null)
  [ -z "$ERRLINES" ] && ERRLINES=$(tail -40 "$CAPTURE" 2>/dev/null)
  RNAMES=(RATE_LIMITED AUTH NO_SESSION MODEL NETWORK GIT)
  RRES=(
    'rate[ _-]?limit|too many requests|usage limit reached|out of usage|quota exceeded|\b429\b'
    'not logged in|unauthorized|invalid api key|authentication failed|\b401\b'
    'no rollout found|thread/resume failed|session not found'
    'model .{0,40}(not found|not supported|unknown)|unknown model|unsupported model'
    'ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|network is unreachable|dns lookup failed'
    'not a git repository|dubious ownership'
  )
  MATCHED=()
  for i in "${!RRES[@]}"; do
    printf '%s\n' "$ERRLINES" | grep -qiE -- "${RRES[$i]}" && MATCHED+=("${RNAMES[$i]}")
  done
  case ${#MATCHED[@]} in
    1) REASON=${MATCHED[0]} ;;
    0) REASON=UNKNOWN ;;
    *) REASON=UNKNOWN
       note "Reason is ambiguous: several classes matched (${MATCHED[*]}). Read the transcript." ;;
  esac
fi

case $REASON in
  RATE_LIMITED) note "REASON: subscription quota exhausted. Wait for the window to reset, or take a lighter route." ;;
  AUTH)         note "REASON: authentication. Run 'codex login' in a terminal -- a script cannot fix this." ;;
  NO_SESSION)   note "REASON: no such session. It was ephemeral, or the id belongs to another run." ;;
  MODEL)        note "REASON: model unavailable on this plan or renamed. Check 'codex debug models' and update bin/routes.conf." ;;
  NETWORK)      note "REASON: network. Retry later; there is no verdict, and inventing one is not an option." ;;
  GIT)          note "REASON: git. Check that dir is a repository and the snapshot was built." ;;
  TIMEOUT)      : ;;
  UNKNOWN)      [ "$CODEX_RC" -ne 0 ] && note "REASON not recognised -- read the transcript above in full." ;;
esac

OUT_SIZE=$(compat_size "$OUT")
HAS_TEXT=no
[ -f "$OUT" ] && grep -q '[^[:space:]]' "$OUT" 2>/dev/null && HAS_TEXT=yes

RUNNER_RC=0
if [ "$CODEX_RC" -ne 0 ]; then
  RUNNER_RC=1
  if [ "$CODEX_RC" -eq 124 ]; then
    note "NO VERDICT: aborted after the ${R_timeout}s timeout."
  else
    note "NO VERDICT: codex exited with code $CODEX_RC."
  fi
elif [ "$OUT_SIZE" -eq 0 ]; then
  # Codex swallows a -o write error and still exits 0, so size is checked separately.
  RUNNER_RC=1; REASON=EMPTY_VERDICT
  note "NO VERDICT: codex exited 0 but the verdict file is empty or was never created."
elif [ "$HAS_TEXT" = no ]; then
  RUNNER_RC=1; REASON=BLANK_VERDICT
  note "NO VERDICT: the verdict file contains only whitespace."
elif [ -n "$(get schema)" ]; then
  # A route that asked for structured output must receive structured output.
  # Without this, ANY non-empty text passes: a run that was diverted by a plugin
  # skill and never looked at the material returns a confident paragraph, and
  # "non-empty" reports it as a verdict. Observed in practice, which is why this
  # check exists.
  # `node -e ''` rather than `command -v node`: a node that is present but
  # cannot run is exactly as useless as an absent one, and this way both
  # collapse into a single condition that a test can actually construct.
  if ! node -e '' >/dev/null 2>&1; then
    # Fail closed. "Could not check" must not read as "checked and fine": that
    # is the exact shape of the failure this check exists to catch.
    RUNNER_RC=1; REASON=NO_VALIDATOR
    note "NO VERDICT: the route requested --output-schema, but node is not usable"
    note "            here, so the result cannot be confirmed to be JSON."
    note "            Install node, or drop 'schema=' from the request."
  elif ! node -e 'const fs=require("fs");JSON.parse(fs.readFileSync(process.argv[1],"utf8"))' "$OUT" 2>/dev/null; then
    RUNNER_RC=1; REASON=NOT_JSON
    note "NO VERDICT: the route requested --output-schema, but the verdict file is not valid JSON."
    note "            Read it: the run was probably diverted before it did any work."
  else
    # Parseable is not enough. `{"findings":[]}` is valid JSON meaning "no
    # objections": a diverted run returning that passed every check above and
    # looked like a clean review. So the verdict is checked against the schema
    # the route itself asked for -- required fields and types, recursively,
    # including the items of arrays and unions such as ["string","null"].
    # Deliberately NOT a full JSON Schema validator: enum, formats and numeric
    # bounds are not checked. The goal is not to validate everything, it is to
    # refuse to accept as a verdict something that contains neither coverage
    # nor a conclusion.
    MISS=$(node -e '
      const fs=require("fs");
      const v=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const s=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
      const miss=[];
      const isObj=t=>t==="object"||(Array.isArray(t)&&t.includes("object"));
      // Unions have to be honoured on the array side too. `sch.type==="array"`
      // is false for ["array","null"], so the items of such a field were never
      // walked and [1] passed against {"items":{"type":"string"}}.
      const isArr=t=>t==="array"||(Array.isArray(t)&&t.includes("array"));
      const typeOk=(val,t)=>(Array.isArray(t)?t:[t]).some(x=>
        x==="string"  ? typeof val==="string"  :
        x==="integer" ? Number.isInteger(val)  :
        x==="number"  ? typeof val==="number"  :
        x==="boolean" ? typeof val==="boolean" :
        x==="null"    ? val===null             :
        x==="object"  ? (val!==null&&typeof val==="object"&&!Array.isArray(val)) :
        x==="array"   ? Array.isArray(val)     : true);
      function chk(val,sch,path){
        if(!sch||typeof sch!=="object")return;
        if(sch.type!==undefined&&!typeOk(val,sch.type)){
          miss.push((path||"<root>")+": type is not "+JSON.stringify(sch.type));return;
        }
        if(isObj(sch.type)&&val&&typeof val==="object"&&!Array.isArray(val)){
          for(const r of sch.required||[]) if(!(r in val)) miss.push((path?path+".":"")+r+": required field missing");
          for(const k of Object.keys(sch.properties||{})) if(k in val) chk(val[k],sch.properties[k],(path?path+".":"")+k);
        }else if(isArr(sch.type)&&Array.isArray(val)){
          if(Number.isInteger(sch.minItems)&&val.length<sch.minItems)
            miss.push((path||"<root>")+": fewer than "+sch.minItems+" items");
          if(sch.items) val.forEach((x,i)=>chk(x,sch.items,(path||"")+"["+i+"]"));
        }
      }
      chk(v,s,"");
      // A rule of this skill, not of JSON Schema: an empty coverage.reviewed
      // means nothing was read, however confident the prose. It is checked here
      // rather than as "minItems" in the schema file because --output-schema is
      // sent to the API, and the structured-output subset there does not accept
      // every JSON Schema keyword. Applied only when the verdict actually has
      // that field, so an unrelated schema of your own is unaffected.
      if(v&&typeof v==="object"&&v.coverage&&Array.isArray(v.coverage.reviewed)
         &&v.coverage.reviewed.length===0)
        miss.push("coverage.reviewed: empty -- nothing was read");
      if(miss.length){console.log(miss.slice(0,6).join("; "));process.exit(1);}
    ' "$OUT" "$(get schema)" 2>/dev/null); NODE_RC=$?
    # Fail closed on both shapes of failure: a non-empty MISS is a real mismatch,
    # an empty MISS with a non-zero exit means the validator itself died (an
    # unparseable schema file, say). A check that reports "fine" when it breaks
    # is worse than no check at all.
    if [ -n "$MISS" ]; then
      RUNNER_RC=1; REASON=SCHEMA_MISMATCH
      note "NO VERDICT: the reply parses as JSON but does not match the requested schema:"
      note "            $MISS"
      note "            This is what a diverted run looks like: a reply exists, work does not."
    elif [ "$NODE_RC" -ne 0 ]; then
      RUNNER_RC=1; REASON=SCHEMA_MISMATCH
      note "NO VERDICT: the schema check did not run (node exited $NODE_RC)."
      note "            Check that the schema file parses as JSON: $(get schema)"
    fi
  fi
fi

log_event finished route "$ROUTE" codex_rc "$CODEX_RC" out_size "$OUT_SIZE" \
  runner_rc "$RUNNER_RC" reason "$REASON" out "$OUT" subject "$SUBJECT"

if [ "$RUNNER_RC" -eq 0 ]; then
  note "VERDICT: $OUT ($OUT_SIZE bytes)"
  printf '%s\n' "$OUT"
fi
exit "$RUNNER_RC"
