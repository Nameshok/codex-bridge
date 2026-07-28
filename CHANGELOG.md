# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - unreleased

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
- **206 regression tests** (126 route, 80 snapshot) that run without a Codex
  subscription.
- **`install.sh`** with `--check` and `--uninstall`. It never overwrites an
  existing config file; where one exists and lacks what the project needs, it
  says so and leaves it alone.
- **`check-all.sh`**, one command answering "is this installation sound?", with
  `--live` for a real call and a check of the stdout contract.
- **Portability layer** (`skill/bin/compat.sh`): GNU/BSD differences in `stat`
  and `date`, and a pure-bash watchdog where `timeout(1)` is absent.
- CI across Linux, macOS and Windows, including a clean-profile install, an
  idempotent re-install, an uninstall, and a check that every executable file is
  pure ASCII.
