---
name: codex-bridge
description: "Call the OpenAI Codex CLI from this machine as a second AI: an independent check of any work — code, a plan, prose, a document, an estimate, a structure — a second opinion on a contested decision, and generation of bitmap images (pictures, icons, textures, sprites, mockups, logos, backgrounds, background removal, variations from a reference). Use when you need your own result checked independently by another model, an architecture or plan criticised before implementation, a diff reviewed before handing it over, a contested decision or a dead end examined — and whenever a task needs an image, icon or any bitmap asset generated or edited that Claude cannot produce. Works in any project and on any task, not only code. Triggers: codex, review, independent check, second opinion, critique this plan, check my code, check this text, re-check the fixes, fresh eyes, generate an image, need an icon, draw, image, imagegen."
---

# Bridge to Codex

> **The mechanism lives in code, not in this text.** `bin/routes.conf` (the
> registry) + `bin/codex-run.sh` (the single entry point) +
> `bin/codex-snapshot.sh` (the git snapshot) + two test suites. Earlier versions
> of this skill all failed the same way: the prose drifted from the verified
> mechanism. Now there is nothing to drift — a script assembles the command, and
> the registry generates the route table. The findings that shaped each rule are
> in `reference/findings.md`.

The Codex CLI must be installed and logged in (`codex login`). A ChatGPT
subscription login is enough; `OPENAI_API_KEY` is neither set nor needed — the
CLI's built-in image generation works without it.

**All commands here are for a POSIX shell (Bash / Git Bash), not PowerShell.**

## How to call it — three steps, always the same

**Step 1. Write the prompt to a file** with a file-writing tool (never through
the shell). Templates: `reference/prompts.md`.

**Step 2. Write the request file** with a file-writing tool:

```
route=review
dir=/path/to/the/material
out_dir=<scratch>
prompt_file=<scratch>/prompt.txt
subject=what exactly is under review - this goes in the log
```

**Step 3. Run it:**

```bash
bash ~/.claude/skills/codex-bridge/bin/codex-run.sh '<scratch>/req.conf'
```

That is all. Model, effort, sandbox, config, timeout and the flag set come from
the registry by route name. A unique verdict filename, the exit-code check, the
non-empty check and the log entry all happen inside the runner.

**Output contract:** stdout is **exactly one line, the path to the verdict
file**. The entire Codex transcript and every warning go to stderr. That is what
makes this form work:

```bash
OUT=$(bash ~/.claude/skills/codex-bridge/bin/codex-run.sh '<scratch>/req.conf') \
  && cat "$OUT"
```

**Why a request file and not arguments.** The shell parses the calling command
**before** this script starts. A path containing `$(...)` or backticks, pasted
literally into that command line, executes in the caller's shell, and no amount
of care inside the script can undo it. Verified: the script received an empty
`argv[1]` while the injected file had already been created. So dangerous values
must never reach a command line at all — only a file written past the shell.

The one path that does travel as an argument is the path to the request file
itself. That name is generated from a timestamp and a PID; nothing in it derives
from foreign data.

### Request fields

| Field | Required | Meaning |
|---|---|---|
| `route` | always | A route name from the table below |
| `dir` | always | Working root (`-C`) |
| `out_dir` | always | Where the verdict goes — a scratch directory **outside the project** |
| `subject` | always | What is under review. Goes in the log; without it the call is refused |
| `prompt_file` | for form `exec` | The prompt file. Forbidden for `review-builtin` |
| `commit` | for `review-builtin` | **Full 40-character SHA** from `codex-snapshot.sh`. `HEAD`, a branch name and an abbreviated SHA are refused: the target must not move. Mutually exclusive with `base` |
| `base` | for `review-builtin` | Branch name: review the whole branch against it. Bypasses **the snapshot and the secret gate** — this reviews the live tree, so say so out loud |
| `session_id` | optional | Continue a session (`resume`). **Strict UUID**: a value like `--last` would land after `resume` as a CLI option and continue somebody else's session |
| `schema` | optional | `--output-schema`, see `reference/review-schema.json` |
| `image` | image routes | A reference image. The line may be repeated |
| `ephemeral` | optional | Only `yes` or `no`. `yes` — the session is not written to disk. A typo (`yees`) or an empty value is **refused**, not silently read as "no" |
| `confirm_background` | background routes | Only `yes` or `no`. Confirmation that the call was started in the background. Obeys `allows` like every other field: on a foreground route it is refused with exit 2 |

An unknown field, an unknown route, or a field outside the route's allowed list
is **refused with exit 2**, never silently defaulted.

### Runner exit codes

| Code | Meaning |
|---|---|
| 0 | Verdict received, non-empty, contains more than whitespace |
| 1 | No verdict: Codex failed, timed out, or the file is empty or blank |
| 2 | Bad request, corrupt registry, or **a gate stopped the call** |
| 3 | The route is background-only and `confirm_background=yes` was not given |
| 9 | Dry run (`CODEX_RUN_DRYRUN=1`) — argv printed, Codex not called |

Exit 9 is deliberately not zero: the contract "0 means a verdict was received"
must not break because a variable leaked into the environment.

**Gates that stop the call with exit 2:** `out_dir` inside `dir` (the verdict
would be written into the material under review — `-o` writes regardless of the
sandbox); a `.codex/config.toml` found in the working directory or above it (it
is not disabled by `--ignore-user-config` and can declare an MCP server with an
arbitrary command); any mismatch between the registry and its schema.

**Exit 3 is a reminder, not an error.** A child script cannot set
`run_in_background` on the caller's behalf, and a foreground tool call will be
cut off partway through. On exit 3, restart the call in the background and add
the confirmation line to the request file.

## Routes

<!-- ROUTES:BEGIN -->
<!-- Generated by bin/gen-routes-table.sh from bin/routes.conf. -->
<!-- Do not edit by hand: your edit is lost on the next generation. -->

| Route | Purpose | Model / effort | Sandbox | Form | Background |
|---|---|---|---|---|---|
| `ping` | Ping, or a short factual question | `gpt-5.6-luna` / `low` | `read-only` | `exec` | foreground ok |
| `bulk` | Bulk mechanical passes and summaries | `gpt-5.6-luna` / `medium` | `read-only` | `exec` | foreground ok |
| `review` | Ordinary review of a diff, with your own instructions | `gpt-5.6-terra` / `high` | `read-only` | `exec` | foreground ok |
| `review-builtin` | Built-in reviewer over a frozen snapshot or a branch (no custom instructions) | `gpt-5.6-terra` / `high` | `read-only` | built-in `review` | foreground ok |
| `review-critical` | Critical-area review -- money, auth, security, database schema | `gpt-5.6-sol` / `xhigh` | `read-only` | `exec` | **background only** |
| `noncode` | Non-code review -- prose, documents, spreadsheets, quotes, layouts | `gpt-5.6-terra` / `high` | `read-only` | `exec` | foreground ok |
| `noncode-critical` | Non-code where a mistake is expensive -- commitments, pricing, legal, published text | `gpt-5.6-sol` / `xhigh` | `read-only` | `exec` | **background only** |
| `plan` | Critique of a plan with no irreversible steps | `gpt-5.6-terra` / `high` | `read-only` | `exec` | foreground ok |
| `plan-critical` | Critique of a plan that contains irreversible steps | `gpt-5.6-sol` / `max` | `read-only` | `exec` | **background only** |
| `diag` | Diagnosing a specific bug | `gpt-5.6-terra` / `high` | `read-only` | `exec` | foreground ok |
| `diag-critical` | Diagnosing races, data corruption, cross-service failures | `gpt-5.6-sol` / `xhigh` | `read-only` | `exec` | **background only** |
| `fanout` | Wide review fanned out to subagents (needs [agents], hence the base config) | `gpt-5.6-sol` / `ultra` | `read-only` | `exec` | **background only** |
| `image-draft` | Draft image | `gpt-5.6-terra` / `medium` | `workspace-write` | `exec` | **background only** |
| `image` | Showcase asset, and people rendered from a reference | `gpt-5.6-sol` / `high` | `workspace-write` | `exec` | **background only** |
| `image-final` | Final polish of a showcase asset | `gpt-5.6-sol` / `max` | `workspace-write` | `exec` | **background only** |

<!-- ROUTES:END -->

**How routes are chosen:** the model by the nature of the task, the effort by
its structure. Saving quota plays no part in the choice. `xhigh` produces more
findings and also more invented ones — which is exactly why every finding must be
checked against the code. Moving `high -> xhigh` buys more than `xhigh -> max`.
Quota is only noticeably consumed on `sol` at `xhigh`/`max`/`ultra`. The
reasoning behind each route is in `reference/models-and-limits.md`.

Timing: `low` ~15-30 s, `medium` ~1-3 min, `high` 3-5 min on terra and 7+ on
sol, `xhigh`/`max`/`ultra` 10-25 min. Image generation takes 160-500 s
regardless of model and effort (render-queue noise), which is why every image
route is background-only.

## Reviewing code in a git repository

A live working tree keeps changing while Codex reads it. A verdict about code
that no longer exists is worse than no verdict — it creates false confidence. So
freeze a snapshot first:

```bash
bash ~/.claude/skills/codex-bridge/bin/codex-snapshot.sh '<repository>'
# -> BASE=<sha>
#    MERGE=no
```

The script prints `BASE`, `MERGE`, and also `LINES` and `FILES` — the size of the
snapshot. Over 2000 patch lines it warns: a non-empty verdict on that much code
is easy to mistake for a full review even though part of the code never reached
the model. Split by meaning, by subsystem. Mechanical chunking is worse — it
severs cross-file context.

It stops with exit 2 in three cases.

1. **A file name** looks like a secret. Tracked, staged and untracked names are
   all checked — `git add -A` takes all three. The gate is deliberately
   conservative: a file deleted only in the working tree will not enter the
   snapshot, yet it still appears in `ls-files` and will stop the call. A
   needless stop is cheaper than a leak.
2. **The content** of added lines looks like a secret: private keys, AWS and
   Google keys, GitHub/GitLab/Slack/Stripe/Docker tokens, JWTs, and a long
   literal assigned to a variable named like `password`/`api_key`/
   `client_secret`. This closes the hole a name-only gate cannot see: a secret
   under a neutral name (`config.yml`, `handler.py`). **Values are never
   printed** — only the patch line number and the kind of match.
3. **The repository arrived carrying its own executable configuration:**
   `filter.*.clean/process/smudge`, `core.fsmonitor`, `core.hooksPath`,
   `core.sshCommand`, `core.pager` in the **local** `.git/config`. This is not
   paranoia: `git add -A` runs a clean filter as a command by design, and
   `git status` runs fsmonitor. Only the local config is checked — machine-wide
   filters such as git-lfs are legitimate and do not block anything.

Then pass `BASE` as a literal SHA in the `commit` field (route `review-builtin`)
or inside the prompt text (the `review*` routes of form `exec`).

Coverage check after the verdict:

```bash
bash ~/.claude/skills/codex-bridge/bin/codex-snapshot.sh --files '<repository>' '<sha>'
```

Compare that list with the files Codex named. **This is a question, not a
proof:** a clean file draws no comment, so a missing name means "not confirmed
as read", not "not read".

Choosing the form: `review-builtin` is the default for ordinary review — the
built-in reviewer brings its own prompt, its own severities and `file:line`
pointers. But it accepts no instructions of yours: a positional prompt is
incompatible with `--commit` and `--base`. If you need your own conditions
(ignore my working notes, report coverage, aim at one subsystem, produce
structured output), use `review` or `review-critical`.

**Keep the volume down.** Lock files, generated code, vendored trees and
binaries will fill the context, and a non-empty answer will be taken for a full
review. In git, exclude with **exact** pathspecs, not `':!*lock*'` — that also
catches `clock.py` and `lock_manager.ts`. Over ~2000 lines, split by meaning.

## Consensus of two models — when a mistake is expensive

The worst failure of an AI review is not the missed finding, it is the
confidently invented one. "Check every finding against the code" is the right
rule, but the list arrives with no priority order. Consensus supplies one
mechanically:

```bash
bash ~/.claude/skills/codex-bridge/bin/codex-consensus.sh '<scratch>/req.conf' review
```

The first run uses the route from the request, the second the named route of a
different model. Required: the request must set `schema` — the merge works on
structured JSON, not on prose.

The output is a single summary file: `agreed` — findings **both** models saw
(look here first), `divergent` — what only one saw (check it sceptically), plus
each run's `coverage` and `overall`.

Matching is **by meaning**. Shared subject matter is a gate: below a minimum
similarity the pair is refused outright, however close the line numbers are. Line
proximity can only rank candidates that already share meaning — otherwise two
unrelated findings on the same line would fuse into a false "agreement".

> **What consensus does NOT give you.** These are two models from the same
> family and the same vendor: a shared training bias produces a shared blind
> spot, and agreement will not catch it. The idea comes from the `deliberate`
> mode of the codex-claude-bridge project, where independence rests on
> **different vendors**; here there is no second vendor, so the independence is
> weaker and agreement is a priority order, not proof. The rule "check every
> finding against the code" still stands.

The cost is two calls instead of one. Use it for critical areas and contested
points, not for routine work. To rebuild a summary from verdicts you already
have, without spending calls:
`codex-consensus.sh --merge-only <verdict1> <verdict2> <route1> <route2> <out.json>`.

## Re-checking the fixes

For critical areas — money, authorisation, security, database schema — a
re-check is **mandatory**. Check only what changed, not the whole diff again.

The cheap way is to continue the same session with `session_id`. The runner
re-applies the full set of protective flags: a bare `codex exec resume` would
inherit the settings of the current invocation — the base config with
`workspace-write` — and hand the reviewer write access to your project.

But remember the cost: `resume` is **no longer an independent look**. Codex is
confirming its own earlier picture. For money and security, take a fresh
snapshot. Take the id from the header of the run you mean, not `--last`: with
several background calls in flight, "the last session" will be somebody else's.

## Roles — the foundation of the bridge

Claude leads: decides, edits code, owns the result. Codex assists: reads,
criticises, judges independently, generates bitmaps. **Codex does not edit
project files.** That is enforced by mechanism, not by wording: every route
except the image ones carries `sandbox: read-only` in the registry, and a request
cannot override it. On the image routes, `-C` points at an asset directory, not
at a project root.

Both tools run on one machine and see one disk, so projects are never uploaded:
Claude names a path and Codex reads it itself.

### What Codex sees — three layers of instruction

1. `~/.codex/AGENTS.md` — global, always loaded (including under
   `--ignore-user-config`). This is what makes Codex a sceptic; the runner greps
   it for the anchor phrase before the first call.
2. `AGENTS.md` in the `-C` directory — **and in directories above it.** The
   runner checks this on **every** call and prints a warning.
3. The call's prompt — **the weakest layer**: instructions in `AGENTS.md`
   outrank it.

### Independence

`-C` exposes your working notes to Codex if they live inside it: the project
journal, the plan, an audit, drafts of decisions. Those are recorded reasoning;
having read them, Codex will confirm you instead of checking you. **Send the
artefact, not the reasoning:** not "I did X via Y because Z".

Before a review, look at what is in the `-C` directory and name in the prompt the
files not to lean on. If the reasoning lives separately from the code, point `-C`
at the code subdirectory instead.

> **The limit of that rule:** the prompt is the weakest layer. A repository's own
> `AGENTS.md` outranks your task, and a line in it saying "read the project
> journal" will override your request. That is why the templates say "do not base
> the verdict on it" rather than "do not read it": the first is achievable, the
> second is a promise the mechanism cannot keep. The runner warns about every
> `AGENTS.md` it finds — when you see that warning, independence is **partial**,
> and that must be said out loud.

## Checking the result

The runner performs both checks itself and exits non-zero on failure:

1. Codex exited non-zero -> there is no verdict.
2. The file exists, is non-empty **and was created by this call** (the unique
   filename guarantees that).

The second check is not a formality: **Codex swallows a `-o` write error** — it
prints `Failed to write last message file` to stderr while the exit code stays 0.

If the runner returns non-zero, say plainly that no verdict was obtained. Do not
fill in for Codex and do not paraphrase what it never said.

**The reason for a failure is named, not left as a number.** The runner parses
the transcript and prints a description: subscription quota exhausted;
authentication — run `codex login` in a terminal; no such session — it was
ephemeral or the id belongs to another run; model unavailable on this plan or
renamed — check `codex debug models` and update the registry; network — retry
later; git; timeout. If it does not recognise the failure it says so and points
you at the transcript.

The **machine label** (`RATE_LIMITED`, `AUTH`, `NO_SESSION`, `MODEL`, `NETWORK`,
`GIT`, `TIMEOUT`, `EMPTY_VERDICT`, `BLANK_VERDICT`, `NOT_JSON`,
`SCHEMA_MISMATCH`, `NO_VALIDATOR`, `UNKNOWN`) goes
into the log as the `reason` field; it is not printed to the terminal.

**A non-empty verdict is not proof that any work was done.** A plugin skill on
the Codex side can take the request over, do something else entirely, and return
a confident paragraph explaining itself. All three checks above pass: the file
exists, it is non-empty, and it contains more than whitespace. This has happened
in practice. Two things reduce it:

- Set `schema` on the route. The runner then requires the verdict not merely to
  parse as JSON but to **match the schema the route asked for**: required fields
  and types are checked recursively, including the items of arrays and unions
  such as `["string","null"]` (`reason: NOT_JSON` when the reply is not JSON at
  all, `SCHEMA_MISMATCH` when the shape is wrong). Parseability alone is not
  enough — `{"findings":[]}` is valid JSON meaning "no objections", and a
  diverted run returning that used to pass as a clean review. Type checking
  alone is not enough either — `{"verdict":false,"summary":1}` has every
  required field and no content. `minItems` is honoured where a schema states
  it; `enum`, string formats and numeric bounds are deliberately not checked.
  The goal is not to validate everything, it is to refuse to accept as a verdict
  something that contains neither coverage nor a conclusion.
- On top of the schema there is one rule of this skill: **an empty
  `coverage.reviewed` is refused.** An empty list means nothing was read,
  however convincing the prose — which is exactly what a diverted run looks
  like. It lives in the runner rather than as `minItems` in the schema file
  because that file is sent to the API as `--output-schema`, and the
  structured-output subset there does not accept every JSON Schema keyword. The
  rule applies only when the verdict actually carries that field, so a schema of
  your own is unaffected.
- Read `coverage.reviewed`. An empty list means nothing was read, however
  convincing the prose is.

If more than one class matches, the reason is reported as `UNKNOWN` rather than
the first match: a wrongly named cause sends you down the wrong path and is worse
than an unnamed one. The whole point of the classification is that an exhausted
quota and a dropped login need different responses, and a bare "exit 1" cannot
tell them apart.

## Call log

`var/calls.jsonl`, one JSON line per event: `started` before the call and
`finished` after. `codex_rc`, `out_size` and `runner_rc` are separate fields —
otherwise "Codex crashed" and "Codex returned 0 but the file is empty" would be
indistinguishable. An orphaned `started` with no `finished` means a killed or
hung call.

> **The log is per machine, not per session.** It holds calls from every agent
> session running in parallel, so `grep -c started` yields a meaningless number
> and cannot be used as a call counter.

To find your own calls, search by `subject` — it is distinct per task, which is
why it is mandatory:

```bash
tail -20 ~/.claude/skills/codex-bridge/var/calls.jsonl \
  | grep '"event":"started"' | grep 'a keyword from your task'
```

**A machine log is not a project journal.** It records that a call happened, not
what was decided. The verdict, and which findings were accepted or rejected,
belong in the project's own notes.

## Secrets — what to screen

Screen **everything that leaves**, not just the diff: plans, questions, file
names, logs, reference images. Never send: `.env*`, `secrets.json`, `*.session`,
`*.pem`, `id_rsa*`, or the contents of `~/.ssh/`.

The `codex-snapshot.sh` gates stop the call on suspicious **names** (tracked,
staged and untracked) and on suspicious **content in added lines** of the patch.
Both are heuristics: unchanged files are not scanned at all, and key names and
formats can only be enumerated partially.

**Before pointing `-C` at a client directory that is not a git repository**, look
at what is in it: the gates only work inside a repository, and `-C` exposes the
whole directory.

If you work under a rule that requires consent before sending client material to
a third-party service, **record that consent in the project's notes**, not in the
conversation — a conversation is summarised and lost, and the consent would be
wrongly reused in a neighbouring project.

## What is NOT guaranteed (say this honestly, do not present it as protection)

- **There is no read boundary at all.** `-C` sets the working root; the sandbox
  restricts writing. Secret protection is behavioural, not enforced.
- **The secret gate is not omniscient.** It checks names, and the content of
  added lines by format (keys, tokens, JWTs, long literal assignments). It will
  not catch: a secret in base64 or another encoding, a short password with no
  recognisable prefix, a secret inside a binary file, or a value on a **removed**
  line (those are deliberately not scanned). No complete list exists; the
  patterns grow as things are found. The last line of defence is reading
  `git show` on the snapshot yourself.
- **Only the snapshot patch is scanned**, not the whole repository. A secret
  sitting in an unchanged file will not enter the snapshot but stays readable to
  Codex through `-C` — that is the read boundary named above.
- **The executable-configuration gate does not cover everything.** It stops a
  local `.git/config` declaring `filter.*`, `diff.*.textconv/command`,
  `core.fsmonitor/hooksPath/sshCommand/pager/editor`, `gpg.program`,
  `sequence.editor` (each key has a test). But `.gitattributes` can invoke a
  filter declared in the machine's GLOBAL config (git-lfs and friends) — those
  are legitimate and deliberately allowed. On top of that, every command that
  builds a patch runs with `--no-textconv --no-ext-diff --no-color`, and hooks,
  fsmonitor, the pager and signature verification are disabled by flags. The set
  of git keys able to execute a command is not closed: a new git release may add
  one the gate does not know about.
- **There is a window between the gate and `git add -A`.** A file created in
  those fractions of a second was never checked. Immaterial for local work, but
  true.
- **A snapshot is still a write.** `add`/`write-tree`/`commit-tree` put objects
  into `.git/objects`. Working files, the index and refs are untouched, but the
  snapshot's contents stay in the repository until garbage collection. That is
  why the gates **stop** rather than warn.
- **Review independence is not absolute** — see the limit of the rule above.
- **The built-in `review` explores the repository on its own**; it is not
  confined to the diff you point it at.
- **A project config outranks the profile.** `--ignore-user-config` does not
  disable `<dir>/.codex/config.toml`. The runner warns when it finds one.
- **`--ignore-user-config` does not disable Codex plugin skills.** Verified: a
  plugin skill loaded and used its MCP tools on a route carrying that flag. The
  flag is about configuration, not about what the model may reach for. A plugin
  can therefore intercept a request whose wording matches its description, which
  makes it one more instruction layer outranking your prompt — like `AGENTS.md`,
  but without any warning from this side, because there is nothing local to
  inspect.
- **The content gate cannot see inside a binary.** git prints `Binary files
  differ` rather than bytes. The snapshot NAMES the binary files it could not
  scan, but naming them is all it can do.
- **The name gate reads the file list line by line** (`ls-files` without `-z`).
  A filename containing a control character would in principle split the line.
  On Windows the case is unreachable — the OS strips such characters, so
  `secr\net` simply becomes `secret` — and git escapes control characters inside
  quotes regardless of `core.quotepath`. On a POSIX filesystem, where such names
  are creatable, this remains a hole: switch the gate to `-z` there.
- **Codex's execution policy rejects some commands.** In practice that is dozens
  of rejections per run, mostly long shell one-liners. This is why the templates
  ask it to name the commands it was not allowed to run: otherwise "checked" and
  "tried and was blocked" look identical.
- **A coverage check does not prove a file was read** — it is grounds for a
  pointed question.
- **An image must be opened and looked at** with a file-reading tool. File size
  and resolution reveal neither a broken composition, nor unreadable text, nor
  something unwanted in the frame.
- **Image generation depends on the Codex CLI's own capability.** It is provided
  by a system skill inside Codex; if your Codex version or account does not have
  it, the image routes will not produce a file, and no amount of configuration
  here changes that.
- **Non-ephemeral sessions accumulate** under `~/.codex/`. The `sessions`
  directory can reach several gigabytes. Check its size every few months.

## When to reach for it — and when not

Always, regardless of schedule, where a mistake is irreversible: a plan that
deletes data, migrates a database, deploys, or rewrites git history; a diff that
touches money, authorisation, security, or a database schema.

After the tests pass and the diff has stopped changing: any other substantive
diff, before you call it done. Reviewing unfinished work is pointless — the edits
made after the review would go unchecked.

On demand: you need a bitmap; two solutions look equally good; you are stuck.

Not for: one- or two-file edits with no external effect, reading, renames,
formatting, or conversational answers.

A useful ceiling is about three calls per task. Treat it as a signal, not a
limit: if you exceed it, say why and carry on. Neither a trivial task nor a very
hard one should be decided by a counter.

One round of criticism per artefact — except in critical areas, where re-checking
the fixes is **mandatory**.

## What to do with the answer

1. The runner returned 0 — there is a verdict. Non-zero — there is none, so say
   so.
2. Check coverage: `codex-snapshot.sh --files` for git, the list of named files
   otherwise.
3. **Verify the claims against the code yourself.** Codex is wrong sometimes and
   confident about it — but it also finds what you missed. Verify rather than
   believe, in both directions. Re-check quoted numbers and paths separately.
4. Accept or reject each finding with a stated reason, out loud.
5. **Record the verdict in the project's notes:** the verdict, what was reviewed
   (snapshot SHA or file list), the model and effort. A review that leaves no
   trace did not happen.
6. The decision is yours. Responsibility for correctness is not shared.

## Failure modes and causes

| Symptom | Cause |
|---|---|
| exit 2, "Unknown route" | Typo in `route`. The list is in the table above |
| exit 2, "does not accept field" | The field is outside this route's `allows`. See `bin/routes.conf` |
| exit 2, "registry: ..." | `bin/routes.conf` is corrupt. The registry is parsed as a schema: a typo in a value fails the call rather than silently changing it |
| exit 2, "out_dir is inside dir" | The verdict would be written into the material under review. Use a scratch directory |
| exit 2, "a project-level Codex config was found" | There is a `.codex/config.toml` in the working directory or above. Read it yourself: it can declare an MCP server with an arbitrary command |
| exit 2, "is not a full lowercase SHA" | You passed `HEAD`, a branch or an abbreviated SHA. Use the 40 characters from `codex-snapshot.sh` |
| exit 2, "is not a UUID" | You passed `--last` or a thread name. Take the id from the header of the run you mean |
| exit 2, "takes only yes or no" | A typo or an empty value in `ephemeral` or `confirm_background`. It used to be read silently as "no" |
| exit 1, "does not match the requested schema" | The reply is JSON but lacks required fields or has wrong types (`reason: SCHEMA_MISMATCH`). The usual sign of a diverted run: a reply exists, work does not |
| exit 1, "the schema check did not run" | The schema file does not parse as JSON. The check fails closed rather than passing the verdict through |
| exit 9 instead of 0 | `CODEX_RUN_DRYRUN=1` is still set in the environment. Codex was not called |
| exit 3 | A background-only route was started in the foreground. Restart it in the background |
| "codex is not logged in" although you are | `codex login status` prints to **stderr** — do not silence it with `2>/dev/null` in your own checks |
| "Codex version drift" | Codex was upgraded. Run both suites, re-check the CLI help, update `bin/expected-codex-version.txt`. In `check-all.sh` this is a **failure**, not a note: on a different CLI version nothing confirms the kit's premises, while the bridge itself keeps working — the runner only warns |
| Empty verdict while Codex exited 0 | A `-o` write error was swallowed. The runner catches this itself |
| Snapshot stopped with exit 2 | A secret gate fired. Deal with the file; do not work around the gate |
| "the repository has no commits" | There is no `--commit` form to use; handle it separately |
| Generation saved no file | A route outside the `image*` family was used, or `~/.codex/claude-safe.config.toml` is missing |
| It asks for `OPENAI_API_KEY` | The run fell back to the CLI image mode instead of the built-in one |

## Rules for editing this kit

0. **DO NOT EDIT `bin/*.sh` WHILE A CALL IS RUNNING.** Bash reads a script in
   chunks as it executes: an edit shifts the offsets, and the running process
   resumes reading from the wrong place — it dies with a syntax error partway
   through. Verified twice. The verdicts survived (Codex writes them itself via
   `-o`), but the runner died before recording `finished`. Check first: the
   command below says either "editing is safe" or "A CALL IS RUNNING".

1. **One command for the state of the whole kit:**

   ```bash
   bash ~/.claude/skills/codex-bridge/bin/check-all.sh
   ```

   File inventory, shell syntax, absence of `eval` and of dash-leading `printf`
   formats, calls in flight, log integrity, table-versus-registry sync, both
   regression suites, and the Codex environment (version against the verified
   one, login, the sceptic AGENTS.md, the profile). `--live` adds one real `ping`
   call and a check of the stdout contract. Run it after any edit and after a
   Codex upgrade.

2. **Routes are edited only in `bin/routes.conf`.** Then run
   `bash bin/gen-routes-table.sh --write`.
3. **Every claim about CLI behaviour must be verified by running a command the
   same day.** Half of what used to break this skill was unverified assumptions,
   not hand-assembled commands. A representative example: `codex login status`
   writes to stderr.
4. **Sections earned through review must survive any shortening:** "Roles",
   "Checking the result", "What is NOT guaranteed", the route table,
   "Independence".

## Reference

- `bin/check-all.sh` — one command: "is this kit intact and working?"
- `bin/codex-consensus.sh` — two runs by different models, findings split into
  agreed and divergent.
- `bin/routes.conf` — the route registry, the single source of truth.
- `bin/compat.sh` — the portability layer (GNU/BSD, missing `timeout`).
- `reference/prompts.md` — four prompt templates and **the canonical output
  contract** (findings with a pointer and a severity, a coverage report, named
  blocked commands). The contract text lives only there; it is deliberately not
  duplicated here, because two copies of one rule drift apart.
- `reference/review-schema.json` — the structured verdict schema.
- `reference/imagegen.md` — what was measured about image generation:
  resolution, identity preservation, upscaling, transparency.
- `reference/models-and-limits.md` — the reasoning behind the routes, subagents,
  quota.
- `reference/findings.md` — the findings that shaped these rules, and how each
  was verified.
