# Design notes

The implementation follows [ContextShadow_Design.tex](ContextShadow_Design.tex)
(v0.1) with these decisions, made after testing it with parallel agents.

## One typed message per checkpoint

v0.1 stores a complete view in every checkpoint: a JSON manifest of active
chunk IDs plus one JSON file per chunk. Each checkpoint now holds a single
file, `message`:

```
kind: learning
id: 3f9c0b2e5d8a4c71b6e0f2a9d4c8b1e7
code: <commit>

Use WAL mode; readers must not block writers.
```

The context at a checkpoint is that checkpoint and its ancestors.
Each new message gets a random 128-bit `id`. Context cherry-pick and rebase
preserve it; `git cs revert` records `retracts: <id>`, so a retraction hides
every copy of that logical message in the effective context.

| Format considered | For | Against |
|---|---|---|
| JSON snapshot (v0.1) | Flexible structure; one checkpoint holds the whole view | Needs `jq`, schema checks and escaping; merge and rebase need a union algorithm that can conflict |
| Plain text | Simplest | No fields, so no kind or code link without guessing |
| Typed message (chosen) | Plain text to read and write; stable message IDs; no `jq` | New structured fields need a format change; earlier messages are hidden by recording a `retract`, not edited in place |

Because each checkpoint holds only its own message, merging is an ordinary
two-parent checkpoint and rebasing copies each message onto the new base;
neither has a message-file conflict. A rebase of merge checkpoints is refused.

## Links between code and context

| Direction | Cardinality | Where it lives |
|---|---|---|
| Code commit to checkpoint | Exactly one for code commits made through participating Git commands when `commit.requireContext` is set (`git cs init`); otherwise at most one through those commands | A native `context` header in the commit object, written by `git commit --context` and `git commit-tree --context` |
| Checkpoint to code commit | Optional, at most one | The `code` field of the checkpoint's message |

The checkpoint cannot name the code commit that links to it: commit IDs hash
their content, so each would need the other's ID first. It names the code it
was captured against instead.

`git commit-tree` can still create an unlinked commit with the setting on. When
given `--context`, it validates and pins the checkpoint; `git cs fsck` reports
unlinked code commits in the selected history. Native link validation checks
the checkpoint's one-file tree shape, not the semantics of the message body.
Stock Git does not implement `commit.requireContext` and can write an unlinked
commit even after `git cs init`; `git cs fsck` catches such commits in the
selected code history.

v0.1 used a `Context-Shadow:` trailer. The native header is typed, cannot be
confused with message text, is kept by `git commit --amend`, `git cherry-pick`
and `git rebase` (including conflicts resolved by hand), and is enforced by
participating commands before a commit exists rather than by a hook or a later
check.

Retention is unchanged: linked checkpoints are kept by pins under
`refs/cs/pins/`, so pushing code never ships context unless `git cs push` is
used.

## Changes from the parallel-agent benchmark report

A benchmark across four real coding tasks (CS versus plain-text notes versus
no sharing) found that the transport worked but cost more agent time and
tokens, and listed concrete defects. Each change below is one commit.

| Report finding | Change |
|---|---|
| `commit --expect <branch>` returned `STALE_TIP` for an unmoved tip | `--expect` resolves context branch names |
| Rebasing onto an already included peer rewrote the tip | `rebase` reports `Already up to date` or fast-forwards |
| 101 notes took about 5 s to read | `context` reads all messages in one `cat-file --batch` pass (100 notes: 3 s to under 0.1 s) |
| `fsck` checked only branch tips' code links | `fsck` checks every reachable checkpoint and reports code commits missing locally |
| A plain `git pull` brought links but no context | `git cs remote <name>` (also run by `init`) adds the fetch refspecs |
| `cs push` published every head; a stale unrelated head blocked a valid push | `push --context <branch>` sends only chosen branches plus the pins the pushed code needs |
| Full-history reads wasted time and prompt space | `context --since/--last/--kind/--from/--path` |
| Catching up took fetch, rebase, diff and show | `sync` merges the team context and prints only unseen messages from others, keeping a read cursor in `refs/cs/seen/` |
| Agents polled with a helper loop | `wait` blocks until named senders have published |
| The coordinator picked relevant notes by hand | `path` fields and `context --path` |
| Contradicting notes stayed visible until a manual revert | `supersedes` field: a correction replaces what it corrects |
| Agents typed their name into every message | `from` field (`--from`, `GIT_CS_FROM`, `cs.from`, author name) |
| Publication-to-read delay was not measured | The `refs/cs/seen/` reflog records when each message was read |
