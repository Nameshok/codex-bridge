# Models, efforts, quota, subagents

> The reasoning and the measurements behind the route table in `SKILL.md`.

> **There is deliberately no route table here.** It lives in ONE place:
> `bin/routes.conf`, from which `SKILL.md` is generated. A copy in a reference
> file would inevitably drift from the original — that is exactly how earlier
> versions of this skill broke. This file holds only what the registry cannot
> express.

## Why only the 5.6 family

Do not reach for other generations (`gpt-5.5`, `gpt-5.4*`,
`gpt-5.3-codex-spark`) at all, not even for a ping: 5.6 is the best available,
and outside the heavy `sol` modes quota is barely consumed. The model catalogue
is listed by `codex debug models`, which also shows the effort ranges and the
context size.

Why `xhigh` for a critical-area review: OpenAI's documentation places security
review at that level.

Moving `high -> xhigh` buys more than `xhigh -> max`. `max` is for one-off
decisions whose cost is irreversible, not for routine work. `xhigh` produces more
findings and also more false hypotheses — which is why "check every finding
against the code" matters more, not less, at that level.

In scripts, always write the full slug (`gpt-5.6-sol`), never the moving alias
`gpt-5.6`. An alias silently repoints when a new model ships, and a route that
claims one model while running another is a lie the tests cannot catch.

## Codex subagents

Enabled through the `[agents]` section of `~/.codex/config.toml` (the installer
adds it): up to 3 parallel threads, subagents defaulting to `gpt-5.6-terra` at
`high` — the main agent thinks, the subagents gather. There is no dedicated CLI
command; **the orchestration is expressed in the prompt.**

The route is `fanout`. It is the only reviewing route that runs with the base
config (`config: base` in the registry): `--ignore-user-config` would discard
`~/.codex/config.toml` along with the `[agents]` section, and there would be no
fan-out at all. The price is reproducibility — plugins and MCP servers come back
into the context. Use it only when you genuinely need the fan-out.

> This route reviews the **live tree** and does not pass through the secret gate.
> Build a snapshot with `codex-snapshot.sh` first and name it in the prompt, or
> state out loud that the review ran against a moving tree with no gate.

Put the orchestration in the prompt file:

```
Review this branch in parallel. Start three subagents with different angles:
security, bugs, tests. Wait for all of them. Return only confirmed findings with
files and line numbers. End with a separate line stating how many subagents
actually ran.
```

**Asking for the count of subagents that ran is mandatory.** Without it there is
no way to distinguish a fanned-out review from an ordinary one: the answer looks
the same either way.

Verified by a live run: three subagents with different angles were requested and
**3 of 3** ran, reported on its own line.

A useful detail from the same run: asked directly "what tools do you have for
launching subagents", Codex answers that it has none. The mechanism is not
exposed as a named tool and exists only in the wording of the prompt. So asking
whether it can do this is useless — verify it by the fan-out actually happening.

When it is worth it: a wide sweep of a repository, a breakdown by independent
subsystems, a large diff. When it is not: one task in one file, where subagents
only burn quota.

Subagents inherit the profile's restrictions and consume quota separately.

## Structured output

The schema is `reference/review-schema.json`, attached through the `schema` field
of the request (on routes that list `schema` in `allows` — see
`bin/routes.conf`). One addition worth knowing:

`--json` additionally emits an event stream for the whole run on stdout, which is
useful when you want to see what Codex did rather than only its conclusion.

## Continuing a session

The form is the `session_id` field in the request. The point: `resume` is cheaper
than a fresh call because the context is already assembled. Verified by content —
the first call was told a number, the resumed session recalled it, and the id in
the header matched.

**An ephemeral session cannot be resumed** — it is never written to disk, so the
choice of `ephemeral=yes` has to be made up front, on the first call.

Trying to resume an ephemeral session produces an explicit error:

```
Error: thread/resume: thread/resume failed: no rollout found for thread id <ID> (code -32600)
```

and exit code 1. That is the good outcome: the refusal is loud, the runner
reports NO VERDICT, and an empty result is never quietly replaced by a fresh
answer to nothing.

> Repeat the full flag set on `resume`. The bare form
> `codex exec resume <ID> "..."` inherits the settings of the current invocation
> — that is, the machine's base config with `workspace-write`.

## Large diffs — not through a pipe

For big changes, do not pipe the diff as text. Let Codex read the repository
itself and pull the parts it needs. The size of a diff does not change which
route to use.

Reviewing a whole branch is the `review-builtin` route with `base` instead of
`commit`:

```
route=review-builtin
dir=<repository>
out_dir=<scratch>
subject=review of the branch against main
base=main
```

> This form bypasses **the snapshot and the secret gate**: it reviews the live
> tree. Run the gate separately (`codex-snapshot.sh` before the call) and say out
> loud that the review ran against a moving tree. `base` fails if the branch is
> named differently or does not exist locally. For very large branches, split the
> review by subsystem or use the `fanout` route.

## Subscription quota — do not economise

Quota consumption is only noticeable on `sol` at effort `xhigh`/`max`/`ultra`.
Everything else — `sol` up to and including `high`, `terra` and `luna` at any
effort, image generation on anything — costs so little that economising is
pointless and harmful: a lowered effort means a worse result for no gain. So
never pick a weaker model or a lower effort "to save quota".

The one decision genuinely worth weighing is `sol` at `xhigh`/`max`/`ultra`: take
it without hesitation when the task deserves it (architecture criticism, a deep
review of a critical area), but do not hang it on routine work where
`terra high` gives the same answer.
