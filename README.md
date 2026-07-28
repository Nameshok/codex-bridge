# codex-bridge

**A Claude Code skill that has a second AI review your work — safely.**

Claude Code calls the OpenAI Codex CLI on the same machine, hands it a frozen
snapshot of your changes, and brings back a verdict. The reviewer runs read-only
and never edits your files. Building that snapshot is what puts the three gates
in the way, and each of them refuses the call rather than hand over a secret it
recognises.

The point is not "another model looks at the code". It is that the *same* model
that wrote the code cannot review it honestly — it inherits its own assumptions.
A different vendor's model does not.

```bash
git clone https://github.com/Nameshok/codex-bridge
cd codex-bridge
bash install.sh
```

That is the whole installation. It checks the prerequisites, writes the two Codex
config files it needs (never overwriting one you already have), appends an
`[agents]` section to `config.toml` when that file has none, copies the skill
into `~/.claude/skills/`, and runs a health check.

Those Codex files go to `~/.codex`, or to `CODEX_HOME` when you have set one —
the installer, the runner and the health check all read the same variable, so
they agree on where they are. It has to be an absolute path; a relative one is
refused rather than resolved, because each of those three would resolve it
against a different directory.

Then just work. The skill loads itself when a task calls for an independent
review, a second opinion, or a generated image — you never invoke it by name.

## Requirements

- **Claude Code**
- **[Codex CLI](https://developers.openai.com/codex)**, logged in
  (`codex login`). A ChatGPT subscription is enough; no `OPENAI_API_KEY` needed.
- **bash, git, node** — all three are almost certainly already installed.
- Linux, macOS, or Windows with Git Bash / WSL.

`timeout(1)` is used if present; on macOS without coreutils a built-in fallback
takes over. Nothing else is required.

## What you get

| | |
|---|---|
| **Frozen snapshots** | A live working tree changes while the reviewer reads it. A verdict about code that no longer exists is worse than no verdict. The snapshot is built in a separate git index, so your staged/unstaged boundary is never touched. |
| **Three gates that stop, not warn** | Secrets by filename, secrets by patch content, and repositories that ship executable git configuration. Each one refuses the call rather than printing a warning you will scroll past. |
| **A route registry** | Model, effort, sandbox, timeout and allowed fields live in one file that is parsed as a schema. A typo fails the call instead of silently changing it. The route table in the docs is *generated* from that file, so that table cannot drift — the surrounding prose is hand-written and can, which is what 1.0.1 is about. |
| **Read-only by default** | Every reviewing route is `sandbox: read-only`, and a request cannot override it. Only the image routes can write, and only into the directory you point them at. |
| **Consensus mode** | Two independent runs with different models, findings mechanically split into "both saw this" and "only one saw this". A priority order for your attention, not a proof. |
| **Named failures** | An exhausted quota, a dropped login and a network fault all look like "exit 1". The runner classifies the transcript and tells you which one it was — and says `UNKNOWN` rather than guessing when the evidence is ambiguous. |
| **221 regression tests** | They run without a Codex subscription. One snapshot case needs a filename Windows cannot create, so a Windows run reports 220. |

## Try it

```bash
bash ~/.claude/skills/codex-bridge/bin/check-all.sh --live
```

Or just ask Claude Code to "get a second opinion on this diff" and watch what
happens.

## What it does not do

This is stated plainly in the skill itself, and it is worth repeating here:

- **There is no read boundary.** The sandbox restricts writing. The working root
  you point at is fully readable to the reviewer. The secret gates are
  heuristics, not a guarantee — they cannot see a base64-encoded key, a short
  password, or a secret inside a binary.
- **The gates belong to the snapshot step, not to every call.** They run when
  `codex-snapshot.sh` builds a snapshot, which is what the review workflow does.
  A request pointed straight at a directory reaches it without them: the runner
  checks the request, not the contents of the tree.
- **Only the snapshot patch is scanned**, not the whole repository.
- **Consensus is not proof.** Both models come from one vendor and one family. A
  shared training bias produces a shared blind spot that agreement will not
  catch.
- **Review independence is partial** whenever an `AGENTS.md` in the target tree
  points the reviewer at your own notes. The runner warns you when it finds one.

`skill/reference/findings.md` records what went wrong along the way, how each
problem was caught, and why every guard exists. If you are going to remove
something because it looks like paranoia, read that first.

## Layout

```
install.sh                       install, --check, --uninstall
skill/
  SKILL.md                       what Claude reads; the route table is generated
  bin/
    routes.conf                  the registry - single source of truth
    codex-run.sh                 the only entry point; argv as an array, no eval
    codex-snapshot.sh            frozen git snapshot + the three gates
    codex-consensus.sh           two runs, findings split by agreement
    compat.sh                    GNU/BSD differences, missing timeout
    check-all.sh                 "is this installation sound?"
    gen-routes-table.sh          registry -> the table in SKILL.md
    test-routes.sh              140 tests
    test-snapshot.sh             81 tests
  reference/                     prompt templates, schema, findings, measurements
```

## Contributing

Two rules, both learned the hard way:

1. **Routes are edited only in `bin/routes.conf`**, then
   `bash skill/bin/gen-routes-table.sh --write`. Never edit the generated table.
2. **Every claim about CLI behaviour must be verified by running a command.**
   Half of what used to break this project was unverified assumptions about how
   the tools behave, not bad code. If you add a claim, add the test that proves
   it.

Before opening a pull request:

```bash
bash skill/bin/check-all.sh
```

## Licence

MIT — see [LICENSE](LICENSE).

Not affiliated with OpenAI or Anthropic. "Codex" and "Claude" are the trademarks
of their respective owners.
