# Security

## What this project's threat model actually is

codex-bridge hands a directory on your machine to a second AI and runs git
commands inside repositories you may not have written. Two things follow, and
both are treated as real attack surface rather than hypothetical:

1. **A repository can execute code on your machine through git alone.** Not
   through an exploit — through documented configuration. `filter.<driver>.clean`
   runs on `git add`, `core.fsmonitor` runs on `git status`, and
   `diff.<driver>.textconv` runs on `git show` and `git diff`. A directory
   somebody sent you carries its own `.git/config`.
2. **Any value that reaches a shell command line can execute.** Paths, subjects,
   prompts and route names all originate outside the script.

The design answers are in `skill/reference/findings.md`, with the runs that
confirmed each one. In short: requests travel as files, never as arguments; argv
is built as an array and `eval` appears nowhere; every patch-building git command
runs with `--no-textconv --no-ext-diff --no-color`; and a gate refuses any
repository whose *local* config declares an executable driver.

## What is deliberately NOT protected

Please read this before reporting. These are known and stated, not oversights:

- **There is no read boundary.** The sandbox restricts writing. Everything under
  the working root you point at is readable by the reviewer.
- **The secret gates are heuristics.** They check file names and the *added*
  lines of the snapshot patch against high-signal formats. They will not catch a
  base64-encoded secret, a short password with no recognisable prefix, a secret
  inside a binary, or a value on a removed line.
- **Only the snapshot patch is scanned**, not the whole repository.
- **There is a window** between the gate and `git add -A`. A file created in
  those fractions of a second was never checked.
- **A snapshot writes objects** into `.git/objects`. Nothing uncommitted can be
  lost, but the snapshot's contents stay in the repository until garbage
  collection. That is precisely why the gates stop the call rather than warn.
- **The list of git keys that can execute a command is not closed.** A future git
  release may add one the gate does not know about.

## Reporting a vulnerability

Open a **private security advisory** through GitHub (Security -> Advisories ->
Report a vulnerability) rather than a public issue.

A useful report contains:

- the exact steps, including a repository or request file that reproduces it;
- what you expected the gate or the runner to do;
- the output of `bash skill/bin/check-all.sh`;
- your Codex CLI version (`codex --version`) and platform.

A finding is far more valuable with a failing test attached. The two suites in
`skill/bin/` run without a Codex subscription, and almost every guard in this
project has a test named after the thing that once got past it.

## Secrets in the repository

Nothing in this repository should ever contain a credential. The test suites
plant *synthetic* secrets on purpose — `AKIAIOSFODNN7EXAMPLE`, `ghp_aBcDe...`,
and similar — to prove the scanners fire. They are literals in test code, they
match no real account, and they must stay: removing them removes the test.
