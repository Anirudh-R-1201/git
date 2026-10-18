# Testing `git cs`

`git cs` (ContextShadow) versions captured context, such as agent messages
and learnings, in a commit history kept apart from code, with explicit links
from code commits to the exact context that produced them. The original design
is [ContextShadow_Design.tex](ContextShadow_Design.tex) (v0.1); implementation
changes from it are recorded in [DESIGN-NOTES.md](DESIGN-NOTES.md).

Start with the [practical guide](../Documentation/git-cs-guide.md) for the
working model and collaboration workflow. The source-backed primitive
reference is in [PRIMITIVES.md](PRIMITIVES.md); current test results are in
[RESULTS.md](RESULTS.md).

There are three layers of tests:

| Layer | Where | What it proves |
|---|---|---|
| Unit | `t/t9905-cs.sh`, `t/t7529-commit-context.sh` | Every `git cs` command and the native `context` field of commits, inside git's own test harness |
| Per command | [cmdtable.sh](cmdtable.sh) | One concrete example per command against a sample project, expected vs received |
| Parallel agents | [agents/](agents/) | Several agents share learnings through `git cs` while coding in parallel |

All of them need the extension built first, from the repository root:

```bash
make
```

## Unit tests

```bash
cd t && ./t9905-cs.sh && ./t7529-commit-context.sh
```

The full Git shell suite and separate C unit suite run from the repository
root:

```bash
make -j12 test
make -C t unit-tests
```

The shell suite includes a local IPC daemon test, which needs permission to
create local sockets.

These also run with the rest of git's suite. Related git suites worth
running after a change: `t0012-help.sh`, `t7500-commit-template-squash-signoff.sh`
and `t7513-interpret-trailers.sh`.

## Per-command table

```bash
cs-testing/cmdtable.sh
```

Each row runs one real example, such as
`git cs merge union agent-b`, normalizes what came back (exit status, stderr,
active chunks, parents, refs moved) into a short string, and compares it with
the expected outcome. Commit IDs and dates are normalized away, so the
expected column never changes between runs.

The script prints `PASS` or `FAIL` per row, writes the full table to
`<sandbox>/cmdtable.md`, and exits non-zero if any row fails.

| Variable | Default | Meaning |
|---|---|---|
| `CS_GIT_BIN` | `bin-wrappers/` of this checkout | Directory holding the `git` to test |
| `CS_SANDBOX` | a new `mktemp -d` directory | Where the sample repositories are created |

Coverage: every command and option, error paths (stale tip, bad kinds,
missing code commits, empty messages, code commits used as checkpoints), the
native `context` field (`git commit --context`, amend, `commit.requireContext`,
`git cherry-pick` and `git rebase` keeping it), concurrency (eight writers from
one tip and eight parallel publishers with `--retry`), retention after
`git gc`, and transfer by push, fetch and bundle.

## Parallel agents sharing learnings

This checks the use case `git cs` exists for: several agents work on one
project at the same time, each on its own code branch, and exchange decisions
only through context.

```bash
cs-testing/agents/setup-team.sh /tmp/cs-team
# start three agents with agents/PROMPT.md (alpha, beta, gamma) and wait for them
cs-testing/agents/verify-team.sh /tmp/cs-team
```

| File | Role |
|---|---|
| [agents/setup-team.sh](agents/setup-team.sh) | Creates the `textstats` project, seeds the team context `main` with two `-m` messages, and adds a worktree per agent |
| [agents/PROMPT.md](agents/PROMPT.md) | The prompt for each agent: the `git cs` commands to use and each agent's task |
| [agents/verify-team.sh](agents/verify-team.sh) | Counts each agent's messages and learnings, reports when each `refs/cs/seen/` cursor first covered a learning, merges the code with linked merge commits, runs the tests, and checks that a fresh clone resolves every link |

The tasks depend on each other: beta uses alpha's tokenizer without seeing
alpha's code, and gamma writes tests from their published contracts. The
context history records what was available to each agent; passing merged
tests alone does not prove an agent used a message.
