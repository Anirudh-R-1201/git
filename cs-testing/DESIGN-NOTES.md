# Design notes

The implementation follows [ContextShadow_Design.tex](ContextShadow_Design.tex)
(v0.1) with these decisions, made after testing it with parallel agents.

## One typed message per checkpoint

v0.1 stores a complete view in every checkpoint: a JSON manifest of active
chunk IDs plus one JSON file per chunk. Each checkpoint now holds a single
file, `message`:

```
kind: learning
code: <commit>

Use WAL mode; readers must not block writers.
```

The context at a checkpoint is that checkpoint and its ancestors.

| Format considered | For | Against |
|---|---|---|
| JSON snapshot (v0.1) | Flexible structure; one checkpoint holds the whole view | Needs `jq`, schema checks and escaping; merge and rebase need a union algorithm that can conflict |
| Plain text | Simplest | No fields, so no kind or code link without guessing |
| Typed message (chosen) | Fixed known fields checked by `git cs`; plain text to read and write; no `jq` | New structured fields need a format change; earlier messages are hidden by recording a `retract`, not edited in place |

Because each checkpoint holds only its own message, merging is an ordinary
two-parent checkpoint and rebasing copies each message onto the new base;
neither can conflict.

## Links between code and context

| Direction | Cardinality | Where it lives |
|---|---|---|
| Code commit to checkpoint | Exactly one when `commit.requireContext` is set (`git cs init`); otherwise at most one | A native `context` header in the commit object, written by `git commit --context` and `git commit-tree --context` |
| Checkpoint to code commit | Optional, at most one | The `code` field of the checkpoint's message |

The checkpoint cannot name the code commit that links to it: commit IDs hash
their content, so each would need the other's ID first. It names the code it
was captured against instead.

v0.1 used a `Context-Shadow:` trailer. The native header is typed, cannot be
confused with message text, is kept by `git commit --amend`, `git cherry-pick`
and `git rebase` (including conflicts resolved by hand), and is enforced
before a commit exists rather than by a hook or a later check.

Retention is unchanged: linked checkpoints are kept by pins under
`refs/cs/pins/`, so pushing code never ships context unless `git cs push` is
used.
