# Prompt templates

Paste these whole; do not paraphrase them. The wording was arrived at the hard
way: "evaluate this plan" returns approval with cosmetic notes, "find what
breaks" returns findings.

**How to pass them.** The prompt is written **to a file** with a file-writing
tool and handed over through the `prompt_file` field of the request. It never
passes through a shell, so the old rules about quotes, backticks and heredoc
delimiters are gone: every character reaches Codex literally.

Replace the `<BASE>` placeholder with the **literal SHA** printed by
`codex-snapshot.sh`. If the snapshot reported `MERGE=yes`, replace
`git show <BASE>` with `git diff <BASE>^1 <BASE>` in templates 1 and 3: the
combined output of `show` on a merge is incomplete.

## The shared output contract — CANONICAL

Substitute this wherever a template says `<output contract>`. Change the
requirements here, in one place; this text is duplicated nowhere else.

> List the findings. Each one carries a precise pointer (`file:line`, or where
> there are no lines: page, slide, cell, layer, timecode, block name), a
> severity (blocker/major/minor/nit), and a mark of "confirmed" or "hypothesis".
> End with a coverage report: what you read, what you deliberately skipped and
> why, what remains unverified, and **which commands you were not allowed to
> run** (the execution policy rejects some calls — without this, "checked" and
> "tried and was blocked" look identical). If you have no objections, say so
> plainly and briefly: an invented finding costs more than a missed one.

> The contract only works on routes of form `exec`. The `review-builtin` route
> will not accept a positional prompt together with `--commit`, so in the frozen
> snapshot form there is no way to attach it: severities and line references
> arrive in the reviewer's own format, and there is no coverage report. In that
> case, check coverage mechanically instead:

```bash
bash ~/.claude/skills/codex-bridge/bin/codex-snapshot.sh --files '<repository>' '<sha>'
```

The script switches to the diff form for merge commits by itself.

## Template 1 — reviewing a diff

```
Review the changes in commit <BASE> in this repository: git show <BASE>.
Base your verdict on the code and the tests. Do not base it on the author's own
notes -- <list the files: journal, plan, audit, backlog, if any are in this
directory>; those contain their reasoning, and it must not stand in for
checking.
Look for: logic errors, edge cases, race conditions, swallowed errors, broken
invariants, tests that do not match the behaviour they claim to test.
<output contract>
```

## Template 2 — criticising a plan

```
Below is a plan, in the <stdin> block. Do not improve it and do not praise it --
find what will break: wrong assumptions, missing steps, irreversible actions
with no safety net, places where ordering matters, steps that cancel each other
out.
Verify the plan's factual claims yourself by reading the files; they are on this
same disk. A claim that fails to check out is the most valuable finding of all.
<output contract>
```

## Template 3 — a critical area (money, authorisation, security, database schema)

```
Review the changes in commit <BASE>: git show <BASE>.
This is a critical area -- <money / authorisation / security / database schema>.
Do not base the verdict on the author's notes; check against the code.
Look specifically for: race conditions and concurrent requests, idempotency of
retries, partial failure halfway through an operation, integrity across tables,
permission checks that can be bypassed, trust placed in input data, data leaking
into logs and responses, whether the migration is reversible.
For each finding, show a concrete scenario: input, state, outcome.
<output contract>
```

## Template 4 — non-code: prose, a document, a spreadsheet, a layout, a file set

For tasks with no git and no code. The subject is named as a list of files
rather than a commit, so coverage is checked against that same list.

```
Review <exactly what: the reply to a client / the quote / the card set / the
layout>.
Files: <list them precisely>.
What this material has to do: <who it is for, what it must achieve, where it
will be published>.
What counts as a defect: a factual error, an internal contradiction, a promise
that cannot be kept, a lost client requirement, an ambiguity that will cause
rework, a violation of a stated constraint (format, size, character limit).
Do not offer stylistic or taste-based edits unless asked for them separately.
<output contract>
```

For material like this the pointer in a finding is not `file:line` but whatever
applies: item number, page, cell, layer, or a quoted fragment of the text.

## What these templates cannot promise

"Do not read file X" is a request, not a guarantee. If the `-C` directory
contains its own `AGENTS.md`, it outranks the task text: a line in it saying
"read the project journal" will override your request not to.

That is why the templates use the achievable wording "do not base the verdict on
it" rather than the unachievable "do not read it".

Before calling, look at the `AGENTS.md` of the target directory. If it pulls
Codex into your own notes, independence is **partial** — say so out loud
alongside the verdict. The real fix is not in the prompt: either point `-C` at a
code subdirectory, or change the project's `AGENTS.md` — and that is editing
somebody else's rules, so do it with the project owner's knowledge.
