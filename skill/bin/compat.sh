#!/usr/bin/env bash
# compat.sh -- platform differences, isolated in one place.
#
# Sourced by every other script. Nothing else in this project may call
# `date +%s%N`, `stat -c`, or `timeout` directly: those three differ between
# GNU (Linux, Git Bash on Windows) and BSD (macOS) userlands, and scattering
# the differences is how a tool becomes "works on my machine".
#
# Every function here degrades loudly, never silently.

# --- unique call id ----------------------------------------------------------
# GNU `date +%s%N` gives nanoseconds; BSD `date` prints a literal "N" instead,
# which would make every id identical and let a stale verdict pass as fresh.
# Seconds + PID + RANDOM is portable and collision-safe enough: two calls would
# have to start in the same second, in the same PID, with the same RANDOM.
compat_call_id() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  case $ns in
    ''|*[!0-9]*) printf '%s-%s-%s' "$(date +%s)" "$$" "${RANDOM}${RANDOM}" ;;
    *)           printf '%s-%s' "$ns" "$$" ;;
  esac
}

# --- file modification time (epoch seconds) ----------------------------------
compat_mtime() {                      # compat_mtime <file> -> epoch seconds or 0
  local f=$1 t
  t=$(stat -c %Y "$f" 2>/dev/null) && case $t in ''|*[!0-9]*) t='' ;; esac
  [ -z "${t:-}" ] && t=$(stat -f %m "$f" 2>/dev/null)
  case ${t:-} in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$t" ;; esac
}

# --- timeout -----------------------------------------------------------------
# macOS ships no `timeout`. Homebrew coreutils installs it as `gtimeout`.
# With neither, we implement it: run the command, run a watchdog, whoever
# finishes first wins. A missing timeout is not acceptable -- a hung call would
# live forever, and this tool exists to make failures visible.
COMPAT_TIMEOUT_KIND=''
compat_timeout_probe() {
  [ -n "$COMPAT_TIMEOUT_KIND" ] && return 0
  if   command -v timeout  >/dev/null 2>&1; then COMPAT_TIMEOUT_KIND=timeout
  elif command -v gtimeout >/dev/null 2>&1; then COMPAT_TIMEOUT_KIND=gtimeout
  else                                           COMPAT_TIMEOUT_KIND=builtin
  fi
}

# compat_timeout <seconds> <command...>   -> exit code of command, 124 on timeout
compat_timeout() {
  compat_timeout_probe
  local secs=$1; shift
  case $COMPAT_TIMEOUT_KIND in
    timeout)  timeout  "$secs" "$@"; return $? ;;
    gtimeout) gtimeout "$secs" "$@"; return $? ;;
  esac

  # Fallback: watchdog in a subshell. Exit code 124 matches timeout(1) so the
  # rest of the code needs no special case.
  #
  # The watchdog leaves a FLAG FILE, and the flag is what decides the exit code.
  # Watchdog liveness cannot decide it: after the TERM the watchdog is still
  # sitting in its grace `sleep`, so "watchdog alive" was read as "the command
  # finished on its own" and the function returned 143 instead of 124 -- exactly
  # the case the caller needs to recognise as a timeout.
  # The flag file is created ONCE by mktemp and never unlinked-then-recreated.
  # The earlier form deleted it and let the watchdog reopen the known path,
  # which on a shared /tmp without protected symlinks is a window for someone
  # else to plant a symlink and have the watchdog truncate a file of theirs.
  # Emptiness is the signal instead: mktemp leaves it empty, the watchdog
  # appends a byte.
  local flag; flag=$(compat_mktemp) || return 125
  # `<&0` is not a no-op here. POSIX and bash redirect the standard input of an
  # ASYNCHRONOUS command to /dev/null when job control is off "in the absence of
  # any explicit redirections" -- which is the case in every non-interactive
  # script. Without this the command ran with an empty stdin, so on any system
  # without timeout(1) (a stock macOS) the prompt never reached Codex at all and
  # the reviewer answered about nothing. Verified by reproducing the exact form
  # the runner uses: `compat_timeout N cmd < file > capture`.
  "$@" <&0 &
  local cmd_pid=$! watch_pid rc
  ( sleep "$secs"
    printf 'x' >> "$flag"
    # Signal the process GROUP first: when the shell has job control the child
    # leads its own group and this reaches what it spawned. In a non-interactive
    # shell job control is usually off, the negative kill fails, and the plain
    # kill below is what actually runs -- so a detached grandchild can still
    # survive. GNU timeout(1) behaves the same way; the limit is documented
    # rather than pretended away.
    kill -TERM "-$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
    sleep 5
    kill -KILL "-$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
  ) 2>/dev/null &
  watch_pid=$!
  wait "$cmd_pid" 2>/dev/null; rc=$?
  if [ -s "$flag" ]; then
    # Timed out. Leave the watchdog running: it still owes the command a KILL
    # after the grace period, and killing it here means a process that ignores
    # TERM is never killed at all.
    rc=124
  else
    kill -TERM "$watch_pid" 2>/dev/null
    wait "$watch_pid" 2>/dev/null
    rm -f "$flag"
  fi
  return "$rc"
}

# --- temp files --------------------------------------------------------------
# BSD mktemp requires a template with at least three X's for some invocations;
# `mktemp -t` means different things on the two platforms. This form works on
# both and never writes outside the system temp dir.
compat_mktemp()     { mktemp "${TMPDIR:-/tmp}/cbridge.XXXXXXXXXX"; }
compat_mktemp_dir() { mktemp -d "${TMPDIR:-/tmp}/cbridge.XXXXXXXXXX"; }

# --- byte size ---------------------------------------------------------------
# `wc -c` prints leading spaces on BSD; strip them so arithmetic works.
compat_size() {                        # compat_size <file> -> bytes, 0 if absent
  local n
  [ -f "$1" ] || { printf '0'; return; }
  n=$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')
  case ${n:-} in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

# --- physical path -----------------------------------------------------------
# `readlink -f` is absent on stock macOS; `cd ... && pwd -P` is universal.
compat_realpath() {                    # compat_realpath <dir> -> physical path
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}

# --- environment report ------------------------------------------------------
compat_report() {
  compat_timeout_probe
  printf 'shell=%s os=%s timeout=%s\n' \
    "${BASH_VERSION:-?}" "$(uname -s 2>/dev/null || echo unknown)" "$COMPAT_TIMEOUT_KIND"
}

# --- absolute-path test, platform aware --------------------------------------
# CODEX_HOME has to be absolute: a relative value is resolved against whatever
# directory each process starts in, and the installer, this kit and Codex itself
# all resolve it separately. What counts as absolute is NOT the same everywhere.
# "C:/tmp" is an absolute path under Git Bash or Cygwin, where a drive letter
# exists; under Linux, macOS or WSL it is a RELATIVE name -- a directory called
# "C:" -- so accepting it there would reintroduce the very problem this test
# exists to prevent. A UNC path (//server/share) is covered by the leading-slash
# case on every platform.
#
# Mind the bracket order in the drive pattern: `[\\/]` matches, `[/\\]` does not.
# With the backslash last, bash treats it as an escape inside the bracket
# expression and the pattern silently stops matching anything -- which reported
# `C:/codex` as "not absolute" on the one platform where it is absolute. The
# suite caught that; reading the code did not.
compat_is_absolute() {
  # Two literal backslashes, built rather than written as a pattern: quoting
  # rules for backslashes inside a case pattern are exactly what broke the drive
  # pattern above, and a variable expanded inside double quotes is matched
  # literally with no escaping to get wrong.
  _compat_unc='\\'
  case $1 in
    /*) return 0 ;;
    [A-Za-z]:[\\/]* | "$_compat_unc"*)
      # Drive letters and backslash UNC paths are absolute only where Windows
      # path semantics apply. Under Linux, macOS or WSL "C:/tmp" is a directory
      # named "C:" relative to the cwd, and a leading backslash is an ordinary
      # character in a filename.
      case ${OSTYPE:-$(uname -s 2>/dev/null || printf unknown)} in
        msys*|cygwin*|win32*|MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}
