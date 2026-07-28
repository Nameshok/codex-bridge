# Findings — why each rule in this kit exists

Every safeguard in `bin/` was paid for. This file records what went wrong, how it
was caught, and what it cost — so that nobody removes a guard because it looks
like paranoia, and so that the same mistakes are not made again from scratch.

Six earlier versions of this skill died the same way: **the prose drifted from
the verified mechanism.** The seventh moved the mechanism out of the text and
into code — a registry, one entry point, and two regression suites. The route
table is generated from the registry and cannot drift.

The rest of the prose still can, and did. The first review after 1.0.0 went
looking for claims rather than defects and found six paragraphs promising what
the code did not do — the last section of this file lists them. Generation fixed
the one table it covers; everything outside those markers is still a claim that
has to be re-checked against the code that moved underneath it.

Two things recur throughout and are worth stating up front:

1. **A static verdict must be confirmed by running it.** A reviewer whose sandbox
   blocks command execution produces confident, plausible findings that turn out
   to be wrong. In one round, three of eighteen findings were wrong for exactly
   that reason — and the most convincing of them was one of the wrong ones.
2. **Fixes break too.** Several defects were introduced by the fixes for earlier
   defects and were caught only by running the suites afterwards. Two of them
   would have made the tool unusable.

## The shell is parsed before your script starts

A wrapper script cannot protect you from injection through its own arguments.
Bash expands `$(...)` and backticks in the calling command **before** the script
is executed. Verified: the script received an empty `argv[1]` while the injected
`touch` had already run.

This is why the runner takes a **request file**, not arguments, and why that file
is written with a file-writing tool rather than through a shell. Every dangerous
value travels as file content, and argv is assembled as an array — `eval` appears
nowhere in the kit, and `check-all.sh` enforces that.

Related traps found along the way:

- A prompt passed inside double quotes executes `$(...)` in the caller's shell.
- A heredoc is terminated by its delimiter appearing in the payload: a line
  reading `PROMPT` inside somebody else's text silently ended the prompt.
- A path containing a single quote does not fail loudly inside single quotes — it
  closes the literal and the rest of the name is executed. That is injection, not
  a syntax error.
- `printf '--- text ---\n'` prints nothing: bash parses a dash-leading format as
  an option. Use `printf '%s\n'`.
- Interpolating a value into a `sed` expression is executable: GNU sed's `s///e`
  flag runs the substitution result as a shell command. A value containing a
  newline injected a second `s` command with `/e` and it executed. Fixed by
  passing the value through `awk -v`, where it is data and cannot become program
  text. `check-all.sh` greps for the pattern so it cannot come back.

## Git runs code the repository supplies

This is documented git behaviour, not an exotic attack:

| Trigger | What runs |
|---|---|
| `git add` | `filter.<driver>.clean` / `.process` / `.smudge` |
| `git status` | `core.fsmonitor` |
| `git show`, `git diff` | `diff.<driver>.textconv`, `diff.<driver>.command` |
| index operations | hooks (`core.hooksPath`) |
| a signed commit | `gpg.program` via `log.showSignature` |

Whatever a flag can disable is disabled (`core.fsmonitor=false`,
`core.hooksPath=/dev/nonexistent-hooks`, `core.pager=cat`,
`log.showSignature=false`, and `--no-textconv --no-ext-diff` on every command
that builds a patch). What no flag disables is caught by a gate on the **local**
`.git/config`.

Two findings were confirmed by planting the config and watching it fire:

- A planted `clean` filter did **not** execute — the gate stopped the snapshot
  first.
- A planted `textconv` **did** execute, because the config gate runs before the
  snapshot while the patch is built afterwards. That is why `--no-textconv` is on
  every patch-building command, and why the gate's key list was widened.

**Only the local config is checked.** The first version read the merged config
and blocked *every* repository on any machine with git-lfs installed, since lfs
declares `filter.lfs.clean` globally. The boundary is the *origin* of the
configuration — `.git/config` travels with a directory somebody sent you; your
global config is your own setup.

**`--includes` is not optional.** `git config --local` reads `.git/config` and
stops there; every ordinary git command expands `include.path`. So a repository
could park the filter in `.git/extra.cfg`, include it from `.git/config`, and
the gate saw nothing while `git add` ran the command. Reproduced: the marker
file appeared and the snapshot exited 0. Adding `--includes` closes it, and
because it only expands directives found *inside* the local file, a machine-wide
git-lfs filter still does not reach the check. Two tests now guard both halves.

## Secret gates

- **Names, from all three sources.** The gate originally checked untracked files
  only, but `git add -A` takes tracked and staged too. A `.env` that was already
  committed sailed straight through.
- **Anchors are the enemy of coverage.** `(^|/)\.env` requires a path start or a
  slash, so `prod.env` and `secret .env` were missed. The working form is
  `\.env($|[./])` — it catches the dotfile, the suffix and `.env.local` while
  leaving `.environment` and `mail.envelope` alone. Other forms that slipped
  through and now have tests: `.env~`, `.env-backup`, `private.pem.bak`,
  `client.key.old`, `id_dsa`, `kubeconfig`, `keystore.jks`, `passwords.kdbx`,
  `.netrc`.
- **Content, not just names.** A secret under a neutral name (`config.yml`,
  `handler.py`) is invisible to a name gate. Gate 3 scans the added lines of the
  patch for high-signal formats.
- **Colour blinds a content scanner.** With `color.diff=always` in the local
  config, diff lines begin with an ANSI escape and `grep '^\+'` matches nothing —
  the gate reported zero added lines instead of two and passed green. `--no-color`
  is load-bearing, not cosmetic.
- **Fail-closed, always.** `grep` exit 1 means "no match"; exit >1 means the check
  itself failed. A form that cannot tell them apart opens the gate exactly when
  grep breaks. There is a test that replaces `grep` with a stub returning 2 and
  asserts the call is refused.
- **A pipeline hides failures.** In `A | grep | grep`, a failure of the first grep
  is lost when the second returns 1: the pipeline reports 1, "no match", and the
  gate opens. The steps are now separate with individual exit-code checks.
- **Do not print what you found.** An early report used `cut -c1-12` on the
  matching line and printed eight characters of the key. Classes are now tested
  one at a time so the report can name the *kind* of match and the line number
  without ever extracting the text. Same rule for git config: key names are
  printed, values never — a command in a config may carry a token.
- A scanner pattern beginning with `-----BEGIN` was parsed by `grep` as an
  option. The gate correctly failed closed and refused every call: right
  behaviour, useless result. Always `grep -- "$pattern"`.

## The registry is a schema, not a hint

Before validation, `config: ignroe` silently meant the base config,
`sandbox: danger-full-access` would have gone straight into `-s`, and fields were
inherited from the previous block when one was missing. Now every value comes
from an enum, every field is mandatory, a duplicate route is refused, and an
unknown field fails the call. `danger-full-access` is rejected explicitly.

The same discipline applies to the generated table: an incomplete block fails
generation rather than inheriting the previous route's model and lying with total
confidence.

`gen-routes-table.sh --write` originally checked only the BEGIN marker — without
END, awk discarded everything after it. Now both markers must exist exactly once,
in the right order, and the result is size-checked before it replaces the file.

## What counts as a verdict

- **Codex swallows a `-o` write error.** It prints `Failed to write last message
  file` to stderr and still exits 0. Size is therefore checked separately.
- A file containing only whitespace was accepted as a verdict.
- When `wc` failed, the size variable stayed empty, the numeric comparison
  errored, the `elif` was skipped, and the exit code stayed 0 — a false success
  with no symptom.
- A dry run originally exited 0. A `CODEX_RUN_DRYRUN=1` left in the environment
  would then have reported success with no call made. Dry runs exit 9.
- The runner's stdout was not a clean channel: the Codex transcript was
  interleaved with the verdict path, so `OUT=$(codex-run.sh req.conf)` returned
  garbage — most visibly with the built-in reviewer, which prints its whole
  verdict to stdout. The transcript now goes to stderr and the one-line stdout
  contract is tested.

**A confident answer is not evidence of work.** A Codex plugin skill matched the
wording of a review request, took the run over, opened a GUI workspace, waited
for a confirmation nobody was there to give, timed out, and returned a polite
paragraph saying so. The runner reported a verdict: the file existed, was
non-empty, and held more than whitespace. Nothing had been read. Two responses
followed — the runner now requires a route that asked for `--output-schema` to
receive parseable JSON (`reason: NOT_JSON`), and the limit is stated in
"What is NOT guaranteed" rather than left as an assumption. The general form of
the problem has no mechanical fix: an external skill is an instruction layer
that outranks the prompt and leaves nothing local to inspect.

The same run corrected a stale belief recorded here earlier: that
`--ignore-user-config` shrinks the toolset to built-ins. It does not disable
plugin skills or their MCP tools. That was true before the plugin system existed
and is a good example of why every claim about CLI behaviour needs re-running,
not re-reading.

**"Parses as JSON" was not enough, and neither was adding types.** Requiring
parseable JSON closed the prose case and nothing else. `{"findings":[]}` is
valid JSON that says "no objections", so a diverted run returning it passed
every check and read as a clean review — and a test in the suite actively
asserted that behaviour as correct. The verdict is now walked against the schema
the route asked for. That fix then broke twice more, each time caught only by
running it:

- The first walk checked objects and arrays and ignored scalars, so
  `{"verdict":false,"summary":1}` passed: every required field present, no
  content in any of them.
- The walk entered arrays on `sch.type === "array"`, which is false for
  `["array","null"]`. Items of a union-typed array were never examined, and
  `[1]` passed against `{"items":{"type":"string"}}`.

Above the schema sits one rule JSON Schema cannot carry here: an empty
`coverage.reviewed` is refused, because it means nothing was read. It is not
written as `minItems` in the schema file because that file goes to the API as
`--output-schema`, and the structured-output subset does not accept every
keyword. The rule fires only when the verdict carries that field, so a schema of
your own is untouched.

The lesson is the old one in a new coat: each of these was a check reporting
success while checking nothing, and each was found by running the validator
against a reply built to defeat it — never by reading the code.

## Naming the reason for a failure

"Exit code 1" looks identical for an exhausted quota, a dropped login and a
network fault, and those need different responses.

The first classifier took the first matching class through an `elif` chain, with
patterns broad enough (`401`, `429`, `login`, `certificate`) to match text inside
the material under review, which is echoed into the transcript. Patterns are now
narrow and anchored, only error-looking lines are searched, and **more than one
match means `UNKNOWN`** — a wrongly named cause sends you down the wrong path and
is worse than an unnamed one. Seven tests drive this through a stub `codex`.

## Consensus matching

Agreement between two runs is a priority order, not proof — and it is worthless
if the matching is wrong.

- The first version took the first candidate within ±3 lines and paired unrelated
  findings ("input validation" at line 5 with "float rounding" at line 8) while
  the real pair was lost.
- Matching on the basename treated `src/config.js` and `tests/config.js` as the
  same file.
- Greedy left-to-right assignment handed the only candidate to a weak pair and
  starved the strong one. Now every pair is scored, sorted, and the strongest are
  assigned first.
- Jaccard similarity punished the normal case: two descriptions of the same
  defect differ in length, and the union inflates. Replaced with the overlap
  coefficient.
- **A shared stop word plus a shared line number crossed the threshold.** One
  incidental "never" was enough for two entirely unrelated findings to be reported
  as agreement. Fixed with a stop-word list and, more importantly, by making
  meaning a **gate**: below a minimum similarity the pair is refused outright,
  however close the lines are. Line proximity can now only rank candidates that
  already share subject matter. This one was found while porting the tool to
  another language, not by the tests that existed at the time.
- Two files containing `{}` produced `degraded=false`, zero counts and prose
  about two sources agreeing. A verdict now counts only if it is valid JSON *and*
  carries a `findings` array.
- Route *names* differing does not make two runs independent: `review` and `plan`
  are both the same model at the same effort. The models and efforts are compared
  through the registry, and identical pairs are refused.

## Tests that lie

- **Expectations derived from the registry are tautologies.** If `review` ever
  became `workspace-write`, a test that reads its expectation from the same
  registry would call that correct. Eight key routes now have their expectations
  written out explicitly.
- `[ $? -eq N ] && ok || bad "rc=$?"` prints the exit code of the *test*, not of
  the command. Capture it on its own line.
- A two-argument helper called with three arguments silently ignored the third:
  `has "$o" -s danger-full-access` degenerated into "is there a `-s` at all",
  which is always true.
- `grep -qxF "-s"` parsed the search string as an option — 19 false failures at
  once. Always `--`.
- A test that copies a production function tests the copy. The log test now
  sources the real `log_event` out of the runner.
- `... | grep -q` closes the pipe on the first match; the producer gets SIGPIPE
  and `pipefail` fails the whole pipeline. A working feature failed its test.
  Capture into a variable first.
- `${PIPESTATUS[1]}` is unset under `set -u` when the assignment came from a
  command substitution — that is one command, so the array has one element.
- A checker that greps for dangerous constructs will find them in itself, in the
  comments explaining why they are avoided. `check-all.sh` excludes itself and
  matches `eval` only in command position.
- **Tests can be blind where a live run is not.** `mktemp` places everything in
  `/tmp`, outside `$HOME`. A gate that walked parent directories therefore looked
  fine in the suite while, in real use, it treated the user's own
  `~/.codex/config.toml` as a project config and blocked every directory under
  `$HOME`. There is now a test that deliberately works inside `$HOME`.

## What a fix can break

Every item here was introduced *by* a fix for something else, and found by
re-reviewing the fixes rather than the original code. This is why a re-check of
the repair is not optional in a critical area.

- **Removing `declare -A` opened an environment channel.** An associative array
  starts empty; plain shell variables are inherited. With request fields held in
  `REQ_<key>`, an environment carrying `REQ_confirm_background=yes` satisfied the
  background gate, and `REQ_route=ping` supplied a route the request file never
  mentioned. Verified: exit 3 became exit 9. The parser now unsets every `REQ_*`
  before reading the file, which is what makes the file the only source.
- **"Could not check" was reported as "checked".** The first version of the
  structured-verdict check skipped validation when node was missing and left the
  run successful — the precise shape of failure the check existed to catch. It
  now fails closed, and tests `node -e ''` rather than `command -v node`, because
  a node that cannot run is as useless as an absent one and only the former can
  be constructed in a test.
- **A flag file that is deleted and recreated is a symlink window.** The timeout
  fallback created the flag with `mktemp`, unlinked it, and let the watchdog
  reopen the known path — on a shared `/tmp` without protected symlinks, someone
  else can own that name in between. The file is now created once and never
  unlinked; emptiness is the signal.
- **Silently dropping malformed findings shrinks a verdict while it still counts
  as complete.** Filtering invalid elements and keeping the rest looked tidy and
  produced a partial verdict presented as a full source. Any malformed element
  now refuses the whole verdict.
- **A `-s` check does not prove a heredoc finished.** A write truncated by a full
  disk leaves a non-empty file, so the installer reported "created AGENTS.md"
  over a half-written reviewer instruction. The write status is checked, and then
  the file is checked for the content that had to be in it.
- **Naming the wrong file is worse than naming none.** For a newly added binary
  git prints `Binary files /dev/null and b/x.bin differ`; stripping the `a/`
  prefix left the report pointing at `/dev/null` instead of the file nobody
  scanned.
- **A checker matches its own text.** The new test forbidding bash-4 constructs
  fired on the comment in `codex-run.sh` explaining why `declare -A` was removed
  — the same trap `check-all.sh` had already solved for `eval`, met again from a
  different direction. Anchor to command position.

## Tests that would not have failed

A re-review asked one question about each new test: would it fail if the fix it
guards were reverted? Several would not, and that is worth recording as its own
class of defect.

- Asserting only "exit code was non-zero" cannot tell a refusal from a crash: an
  unhandled `TypeError` also exits non-zero. The assertion now rejects a
  `TypeError` explicitly.
- A test whose inputs are already degraded proves nothing about a fix that only
  matters on the healthy path. The relative-output-path test used a pair that
  exits 3 either way, so the old `require()` bug would have passed it. It now
  demands exit 0 and `degraded=false`.
- A stub that breaks *every* `grep` cannot show which gate failed closed: with
  all of them broken, deleting one gate's check still leaves another to return 2.
  Each gate is now broken on its own, with a pass-through stub as the control.
- A cap nobody exceeds is not tested. A limit needs an input past the limit.
- Where a platform cannot construct the case at all — a control character in a
  filename on Windows — the suites now report **skip**, not **ok**. Counting an
  unconstructable case as a pass is how a suite comes to look green having
  proved nothing.

## Portability, learned the hard way

- **`declare -A` needs bash 4, and stock macOS ships 3.2** (2007). One
  associative array in the runner would have aborted on the first real line of
  work on a platform this project claims to support. Replaced with `printf -v`
  and a seen-list — same two properties, no `eval`, works on 3.2. The installer
  now reports the bash version so a reintroduction surfaces immediately.
- **The pure-bash timeout fallback returned 143, not 124.** It decided "the
  command finished on its own" by checking whether the watchdog was still
  alive — but after sending TERM the watchdog is still sitting in its grace
  `sleep`, so a genuine timeout looked like a normal exit and the runner
  classified an aborted call as a generic failure. The watchdog now leaves a flag
  file, and the flag decides. This path had no test at all, which is why it was
  wrong for so long; it has three now.
- **`seq` is not guaranteed outside GNU userland.** A test that fails because a
  tool is missing reports a defect that is not there. Replaced with a bash loop.

## A checker that reads nothing passes everything

`SCAN=$(ls "$BIN"/*.sh | ...)` expanded unquoted, so a path containing a space —
`C:/Claude Skills/...` — was word-split into fragments, grep found no such files,
`wc -l` counted zero, and all three "dangerous construct" checks printed ok while
reading nothing at all. Verified by planting a real `eval` and watching it go
unreported. It is now an array, and each check distinguishes grep's exit 1 (clean)
from anything above 1 (the check itself broke).

The general lesson is the one this whole file keeps repeating: a check that
cannot fail is worse than no check, because it also removes the suspicion that
would have made someone look.

## Verified CLI behaviour

Facts that were checked by running a command, not read from documentation. Re-run
the suites after a Codex upgrade; `bin/expected-codex-version.txt` records the
version these were verified against.

| Claim | Reality |
|---|---|
| `codex login status` | Prints "Logged in" to **stderr** and exits 0. A check with `2>/dev/null` silently declares the bridge missing |
| `--ignore-user-config` + `-s workspace-write` | The header shows `read-only`: the sandbox silently degrades, in any flag order and via `-c sandbox_mode` too. `-s danger-full-access` passes, so it is `workspace-write` specifically that degrades |
| A V2 profile | **Is** the file `$CODEX_HOME/<name>.config.toml`; no `[profiles]` section is needed. It is cancelled by `--ignore-user-config`, which is why routes that write must use the base config |
| `--ignore-user-config` and plugins | It does **not** disable plugin skills or their MCP tools. Verified: a plugin skill ran, and used MCP tools, on a route carrying the flag |
| `-p` with a typo | Silently ignored |
| `-i` | Declared variadic (`-i, --image <FILE>...`), so the space-separated form can swallow the next argument. Use `--image=FILE` |
| Built-in `review` | Accepts a positional prompt, but **not together with** `--commit` / `--base` / `--uncommitted` |
| `git show` on a `git stash create` commit | **Zero patch lines** — it is a merge commit. `git diff <sha>^1 <sha>` shows the real diff. Hence `commit-tree -p HEAD`, which gives exactly one parent |
| `"$BASE^"` | Fails on a root commit (exit 128). `git show --name-only --format=` works there |
| Names with spaces and non-ASCII | Break a `git status --porcelain` + `awk` screen (paths arrive quoted and escaped). Use `-c core.quotepath=false ls-files` |
| `git` under `-s read-only` | Runs freely; `dubious ownership` did not reproduce |
| Resuming an ephemeral session | Not silent — it errors with `no rollout found for thread id` and exits 1. Good: the refusal is loud |
| Execution policy | Rejects a fraction of commands, mostly long shell one-liners. This is why the templates ask for blocked commands to be named |
| Subagents | Not exposed as a named tool — asked directly, Codex says it has none. Orchestration lives in the prompt, and the only proof is a fan-out that actually happened |

## Operational lesson

**Do not edit `bin/*.sh` while a call is running.** Bash reads a script in chunks
as it executes; an edit shifts the offsets and the running process resumes from
the wrong place, dying with a syntax error partway through. This happened twice
in one session. The verdicts survived — Codex writes them itself via `-o` — but
the runner died before recording `finished`, leaving orphaned `started` entries.
That is exactly what the orphan detection is for, and `check-all.sh` reports
calls in flight before you edit anything.

## Deliberately not adopted

Ideas from comparable projects that were considered and rejected, with the
reason:

- **A second vendor for genuine independence.** The strongest version of the
  consensus idea, and unavailable here — there is only one vendor on the other
  side of this bridge. The weakness is stated out loud instead of being papered
  over.
- **Mechanical chunking by token count.** It severs cross-file context. The
  approach here is to let Codex read the repository itself through `-C`, and to
  warn about volume rather than silently truncate.
- **A project-level config for the bridge.** It would break the single source of
  truth that makes the generated route table trustworthy.
- **SQLite instead of JSONL** for the call log. A JSONL append under 4096 bytes is
  atomic, which is all the concurrency guarantee this needs — verified by three
  simultaneous calls producing exactly six valid lines.
- **Exposing the bridge as an MCP server.** A skill already works, with less
  moving machinery.

## Documentation that promised more than the code delivered

The first review after the 1.0.0 tag went looking for claims rather than bugs,
and the claims lost. Each of these was confirmed by running something, not by
reading.

- **"never sees a secret the gates can recognise" (README).** The gates live in
  `codex-snapshot.sh`. `codex-run.sh` never calls it. A dry run of `route=review`
  against a repository holding a plain `.env` produced `-C <repo>` and no
  refusal, while `codex-snapshot.sh` on that same repository stopped with exit 2.
  The gates protect the review workflow because that workflow builds a snapshot
  first — not because the runner enforces them. The README now says so, and the
  limitation is listed with the others rather than contradicted three paragraphs
  later by "there is no read boundary".
- **"where a config file exists ... it says so and leaves it alone" (CHANGELOG).**
  Installing into a throwaway HOME whose `config.toml` had no `[agents]` section
  appended five lines to it without asking. True of `AGENTS.md` and the profile,
  false of `config.toml`. The behaviour is deliberate — without `[agents]` the
  fanout route silently stops fanning out — so the text changed, not the code.
- **"On the image routes, `-C` points at an asset directory" (SKILL.md).** It sat
  inside a paragraph opening with "enforced by mechanism, not by wording", and
  the mechanism does not enforce it: the runner checks that `dir` exists and
  passes it through. A dry run of `route=image` with `dir=<project root>` yielded
  `-s workspace-write -C <project root>`. That is a convention, and it is now
  labelled as one.
- **"The runner warns when it finds one" about a project `.codex/config.toml`.**
  It exits 2. Two other lines of the same file already said "stop"; one said
  "warns". A document that contradicts itself is worse than one that is merely
  wrong, because a reader cannot tell which half to trust.
- **"this remains a hole: switch the gate to `-z`" about control characters in
  filenames.** The gate already refuses any C-quoted name outright, and
  `test-snapshot.sh` proves it on POSIX, where such a name can be created. The
  documentation was understating its own protection — the mirror image of every
  other item here, and just as misleading.
- **A health check that could not find a correct install.** `install.sh` honours
  `CODEX_HOME`; `codex-run.sh` and `check-all.sh` read `$HOME/.codex` literally.
  Installing with `CODEX_HOME` set wrote three files where it was told and then
  reported "3 FAILURES -- resolve before using", pointing at the step that had
  just succeeded. Both readers now use `${CODEX_HOME:-$HOME/.codex}`.
- **Consensus accepted one model as two.** The independence check compared
  `model/effort`, so `review-critical` (sol/xhigh) and `plan-critical` (sol/max)
  passed as different — the run printed `gpt-5.6-sol` twice and continued. More
  effort buys more findings from the same weights; it does not buy a second
  opinion. The check now compares the model slug.
- **A silent call log.** A failed append left no line and no complaint, which
  reads afterwards as "no call was made" rather than "the log could not be
  written". The call still proceeds — a verdict outweighs its bookkeeping — but
  it now says so on stderr.

The pattern worth keeping: every one of these was a sentence nobody re-read after
the code beneath it changed. Prose that describes a mechanism has to be tested
like the mechanism, and the only test that works is running the thing and
comparing.

### The fixes needed fixing, again

Re-reviewing the patch above — the rule that a fix gets checked like any other
change — found three defects introduced by it, which is exactly the pattern
recorded at the top of this file.

- **A resolver that resolves differently per process.** Replacing `$HOME/.codex`
  with `${CODEX_HOME:-$HOME/.codex}` fixed the mismatch with the installer and
  created a subtler one: a relative `CODEX_HOME` is resolved against whatever
  directory each process starts in, so the installer, the runner, the health
  check and Codex itself could each mean a different folder. The `claude-safe`
  profile — the net under the routes that may write — is found by that path.
  Resolving it in the scripts would only have moved the disagreement to Codex,
  which resolves it once more on its own, so all three refuse a relative value
  instead.
- **A guard that spends before it decides.** Comparing model slugs made the
  independence check correct for well-formed registries and left it open for
  broken ones: `route_field` returns an empty string for a missing field, an
  empty slug compares unequal to a real one, and both runs started. The refusal
  arrived from the runner, after the first call had been spent. Verified by
  deleting one `model:` line in a copy and watching both runs begin.
- **A test that could pass for the wrong reason.** The new regression case
  asserted only `rc=2`. A missing `node`, an unreadable schema or an empty
  registry field all exit 2 as well, so the test would have gone green while
  proving nothing. Worse, a real regression there means the pair is *accepted* —
  and an accepted pair calls Codex twice for real, so a failing test would have
  spent quota. Both new cases now force `CODEX_RUN_DRYRUN=1` and assert the
  message, not the code.

The rule this leaves: **a fix inherits the burden of proof from the defect.**
Reviewing the patch that closes a finding is not ceremony; here it caught more
than the original pass did.

### Two rounds of fixes, two more defects in them

The patch that fixed the fixes was itself reviewed, and it too was wrong twice.
Recording this because the shape repeats: each round narrowed the hole rather
than closing it, and only running the case showed which.

- **"Absolute" is not one thing.** The guard for `CODEX_HOME` accepted a
  drive-letter path on every platform. Under Git Bash `C:/tmp` is absolute; under
  Linux, macOS or WSL it is a directory named `C:` relative to the cwd, so on the
  three platforms where the guard mattered most it would have waved through the
  exact class of value it was written to stop. The test is now one function,
  `compat_is_absolute`, and the suite asserts both halves — drive paths absolute
  where drives exist, relative where they do not — so it can run unchanged on all
  three CI runners.
- **Non-empty is not the same as filled in.** The consensus guard tested `[ -n
  "$MODEL" ]`. A registry line reading `model:` followed by spaces yields `"   "`:
  non-empty, unequal to any real slug, accepted as independent. Both runs started
  and the first call was spent before the runner rejected the second — the same
  failure the previous round had just fixed, reached through a different door.
  Confirmed by planting the blank line and watching `run 1` and `run 2` appear.
- **And the fix for the first one was written wrong.** The new
  `compat_is_absolute` used the pattern `[A-Za-z]:[/\\]*`. Inside a bracket
  expression bash consumes a trailing backslash as an escape, so the pattern
  matched nothing at all and `C:/codex` was reported as *not* absolute — on the
  one platform where it is. Written with the backslash first, `[\\/]`, it works.
  Nothing about the line looks wrong; the suite failed two assertions the first
  time it ran, which is the only reason this was caught rather than shipped.

A fourth round found two more, both introduced by the third:

- **A guard that blocked its own removal.** Sourcing `compat.sh` for the new
  check was placed above the `--uninstall` branch, so an incomplete checkout made
  uninstalling impossible: the script exited before reaching the code that
  removes the installed copy, and the installed copy was the thing you were
  trying to get rid of. Removing an installation must never depend on the state
  of the source tree. Reproduced by deleting `compat.sh` from a copy and watching
  the skill directory survive `--uninstall`.
- **The same backslash trap, one line down.** `\\server\share` is an absolute
  path on Windows and was classified as relative, because the guard recognised
  only the `//server/share` spelling. Writing the pattern inline invites exactly
  the quoting mistake made above, so it is built from a literal variable and
  matched inside double quotes, where nothing is escaped and nothing can be
  mis-escaped.

One finding from that round was **rejected**: that a user who sets
`MSYS2_ENV_CONV_EXCL=CODEX_HOME` makes bash and Codex resolve the same absolute
string to different directories. True, and outside what this guard can do — it
checks the *shape* of a path, not the identity of its resolution in two
runtimes. Disabling MSYS path translation breaks that agreement for every tool
on the machine at once. It is now stated as a limitation instead of being
silently patched over.

Both were found by a review of the fix, not of the original code. The cost of
that review was one call; the cost of shipping either defect would have been a
silently weakened guard in the part of the kit whose entire purpose is to be
trustworthy when it says no.
