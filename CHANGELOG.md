# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-07-29

The first review after publication went after the claims rather than the code,
and found the documentation promising what the code did not do. Every item below
was confirmed by running something; the reasoning and the runs are in
`skill/reference/findings.md`.

### Fixed

- **`CODEX_HOME` was honoured by the installer and ignored by everything else.**
  `codex-run.sh` and `check-all.sh` read `$HOME/.codex` literally, so an install
  under a custom `CODEX_HOME` wrote its files where it was told and was then
  reported as three failures. Both now use `${CODEX_HOME:-$HOME/.codex}`.
- **Consensus accepted one model as two.** The independence check compared
  `model/effort`, so two routes sharing a model but differing in effort passed as
  independent. It compares the model slug now: a higher effort is more findings
  from the same weights, not a second opinion.
- **Consensus started spending calls on a registry it could not read.** A route
  missing its `model` line yielded an empty slug, an empty slug compares unequal
  to a real one, and both runs began; the refusal arrived from the runner after
  the first call was already gone. The check now fails closed before anything is
  spent.
- **`CODEX_HOME` is required to be absolute.** A relative value resolves against
  the directory each process starts in, so the installer, the runner, the health
  check and Codex itself could each mean a different folder — and the profile
  that keeps the image routes from writing where they should not is found by that
  path. All three scripts refuse a relative value instead of guessing.
  What counts as absolute is platform-dependent and now lives in one function,
  `compat_is_absolute`: `C:/tmp` is absolute under Git Bash or Cygwin and is a
  *relative* name under Linux, macOS and WSL — a directory called `C:`. The first
  version of the guard accepted it everywhere, which would have passed exactly
  the kind of value it exists to reject. The installer sources the same function
  from the kit it is installing, so the two cannot disagree.
- **A blank `model` line passed the consensus guard.** Requiring a non-empty
  string was not enough: `model:` followed by spaces yields `"   "`, which is
  non-empty and compares unequal to a real slug, so both runs started again and
  the first was paid for before the runner rejected the second. The check now
  requires a non-blank character.
- **`install.sh --uninstall` stopped working on an incomplete checkout.** The
  new `CODEX_HOME` check sourced `compat.sh` before the uninstall branch, so a
  missing file left the installed skill in place with nothing able to remove it.
  Removing an installed copy must not depend on the state of the source tree;
  the check now runs after that branch. Confirmed both ways by deleting
  `compat.sh` from a copy and running `--uninstall`.
- **A backslash UNC path was classified as relative.** `\\server\share` is
  absolute on Windows, and the first version of the guard only recognised the
  `//server/share` form. It failed closed, so nothing unsafe followed, but the
  classification was wrong. The pattern is built from a literal variable rather
  than written inline — the same backslash-quoting trap that broke the drive
  pattern applies here too.
- **A failed write to the call log was silent**, leaving a gap that later reads
  as "no call was made". The call still proceeds; the runner now says so on
  stderr.

### Added

- Two regression tests for the consensus fixes above. The existing "identical
  models" case paired `review` with `plan`, which share model *and* effort, so it
  passed under either comparison and proved nothing about the weaker one. The new
  cases pair two routes sharing only the model, and run a copy of the kit against
  a registry whose `model` line has been removed. Both assert the message, not
  just the exit code — a missing `node` or an unreadable schema also exits 2, and
  a test that cannot tell those apart reports a green tick for the wrong reason.
  Both force `CODEX_RUN_DRYRUN=1`, because a regression here means the pair is
  *accepted*, and an accepted pair goes on to call Codex twice for real: a failing
  test must not spend quota.
- A third consensus case for a `model` line that is present but blank, and ten
  cases for `compat_is_absolute`: POSIX paths, both spellings of a UNC path, a
  single leading backslash (which is not one), bare names, dot-relative paths, an
  unexpanded tilde, the empty string, and drive-letter paths — the last three
  asserted *both* ways depending on the platform, so one suite runs unchanged on
  all three CI runners. The drive pair failed on its first run and caught a real
  defect in the guard it was written for: `[A-Za-z]:[/\\]*` matches nothing,
  because bash consumes the trailing backslash inside a bracket expression.
  Written `[\\/]` it works. Route suite: 127 -> 140 tests, 221 in total
  (220 on Windows).

### Changed

- README no longer claims the reviewer "never sees a secret the gates can
  recognise". The gates run in the snapshot step, and a route pointed straight at
  a directory does not pass through them — now stated where the other limits are.
- README and CHANGELOG now say that `install.sh` appends an `[agents]` section to
  an existing `config.toml`. It never overwrote a file, but "leaves it alone" was
  not true of that one.
- SKILL.md no longer presents the image routes' asset directory as enforced by
  mechanism. It is a convention; the runner passes whatever `dir` names.
- SKILL.md said the runner "warns" about a project-level `.codex/config.toml`
  while two other lines in the same file said it stops. It stops, with exit 2.
- SKILL.md called control characters in filenames an open hole. The gate already
  refuses C-quoted names, and `test-snapshot.sh` proves it on POSIX.
- The published test count was wrong. 1.0.0 shipped 208 (127 route, 81 snapshot),
  not 207: a Windows run reports one fewer because a single snapshot case needs a
  filename NTFS cannot create, and that platform-specific number was the one
  written down. With the tests added above the totals are 221, or 220 on Windows.
- `install.sh` documented itself the same way the CHANGELOG did — "the file is
  left alone" — while appending to `config.toml`. Its header now says which file
  it edits and why.
- SKILL.md and `findings.md` both opened by claiming there was "nothing left to
  drift". Generation covers the route table between its markers; the rest is
  hand-written prose, and this release exists because six paragraphs of it had
  drifted. Both now say which part is generated and which is a claim to check.
- `~/.codex` is documented as the default rather than the location, in README,
  SKILL.md, `models-and-limits.md` and the installer header.

## [1.0.0] - 2026-07-29

First public release. The project existed privately through six earlier
iterations; what follows describes the state being published, not the path to
it. That path is recorded in `skill/reference/findings.md`.

### Added

- **Route registry** (`skill/bin/routes.conf`) as the single source of truth for
  model, effort, sandbox, config layer, timeout, form, background requirement and
  allowed request fields. Parsed as a schema: an unknown route, an unknown field
  or a value outside its enum refuses the call rather than defaulting silently.
- **One entry point** (`skill/bin/codex-run.sh`). Requests arrive as files, argv
  is assembled as an array, `eval` is used nowhere. Exit codes distinguish a
  verdict, no verdict, a bad request, a background-only route and a dry run.
- **Frozen git snapshots** (`skill/bin/codex-snapshot.sh`) built in a separate
  index, so the working tree's staged/unstaged boundary is untouched, with three
  gates that stop the call: secrets by file name, secrets by patch content, and
  repositories carrying executable git configuration.
- **Consensus mode** (`skill/bin/codex-consensus.sh`): two runs with different
  models, findings split into agreed and divergent by meaning rather than by line
  proximity.
- **Failure classification** — `RATE_LIMITED`, `AUTH`, `NO_SESSION`, `MODEL`,
  `NETWORK`, `GIT`, `TIMEOUT`, `EMPTY_VERDICT`, `BLANK_VERDICT`, `NOT_JSON`,
  `SCHEMA_MISMATCH`, `NO_VALIDATOR`, `UNKNOWN` —
  reported in prose and logged as a machine label. Ambiguity reports `UNKNOWN`
  rather than guessing.
- **Verdict validated against the schema it asked for.** A route with `schema=`
  requires more than parseable JSON: required fields and types are walked
  recursively, including array items, `["string","null"]` unions and `minItems`.
  Parseability alone would accept `{"findings":[]}` — valid JSON meaning "no
  objections" — and a type check alone would accept
  `{"verdict":false,"summary":1}`. On top of the schema, an empty
  `coverage.reviewed` is refused: it means nothing was read. The check fails
  closed — an unparseable schema file, or a validator that dies, is a refusal
  and never a pass (`reason: SCHEMA_MISMATCH`).
- **Switch fields are an enumeration.** `ephemeral` and `confirm_background`
  take only `yes` or `no`; a typo or an empty value is refused rather than read
  silently as "no". `confirm_background` obeys `allows` like every other field.
- **Generated documentation**: the route table in `SKILL.md` is produced from the
  registry by `gen-routes-table.sh`, and `--check` fails the test suite if the
  two drift apart.
- **208 regression tests** (127 route, 81 snapshot) that run without a Codex
  subscription. One snapshot case needs a filename Windows cannot create, so a
  Windows run reports 207.
- **`install.sh`** with `--check` and `--uninstall`. It never overwrites a Codex
  config file: `AGENTS.md` and the `claude-safe` profile are created only when
  absent, and an `AGENTS.md` without the reviewer instruction is reported and
  left alone unless you agree to the append. The one file it edits on its own is
  `config.toml`, where a missing `[agents]` section is appended — the fanout
  route needs it, and without it that route silently stops fanning out.
- **`check-all.sh`**, one command answering "is this installation sound?", with
  `--live` for a real call and a check of the stdout contract.
- **Portability layer** (`skill/bin/compat.sh`): GNU/BSD differences in `stat`
  and `date`, and a pure-bash watchdog where `timeout(1)` is absent.
- CI across Linux, macOS and Windows, including a clean-profile install, an
  idempotent re-install, an uninstall, and a check that every executable file is
  pure ASCII.

[1.0.1]: https://github.com/Nameshok/codex-bridge/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Nameshok/codex-bridge/releases/tag/v1.0.0
