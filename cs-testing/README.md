# Testing `git cs`

`git cs` (ContextShadow) versions captured context, such as agent messages
and learnings, in a commit history kept apart from code, with explicit links
from code commits to the exact context that produced them. The behaviour it
must have is defined by the design document in this directory,
[ContextShadow_Design.tex](ContextShadow_Design.tex) (v0.1).

There are three layers of tests:

| Layer | Where | What it proves |
|---|---|---|
| Unit | `t/t9905-cs.sh` | Every command and error path, inside git's own test harness |
| Per command | [cmdtable.sh](cmdtable.sh) | One concrete example per command against a sample project, expected vs received |
| Parallel agents | [agents/](agents/) | Several agents share learnings through `git cs` while coding in parallel |

All of them need the extension built first, from the repository root:

```bash
make
```

`git cs` requires `jq`.

## Unit tests

```bash
cd t && ./t9905-cs.sh
```

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

Coverage: every command and option, error paths (stale tip, invalid payload,
identity and order conflicts, code commits used as checkpoints), plain-text
messages (`commit -m`, `show --messages`), concurrency (eight writers from one
tip, eight parallel publishers with and without `--retry`), retention after
`git gc`, and transfer by push, fetch and bundle.
