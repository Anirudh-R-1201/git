# Git-CS: a practical guide

Git-CS keeps **agent-authored context** in Git history beside the code history. A
context message can state a decision, interface contract, discovery, or blocker
while another contributor is still working. Code commits can point to the
checkpoint they used. This makes the shared information inspectable and
transferable; Git-CS does not capture an agent's conversation or hidden model
reasoning automatically.

This guide describes the implementation in this checkout. For exact flags and
argument rules, see [git-cs(1)](git-cs.adoc). For source-level details and test
results, see [the primitive inventory](../cs-testing/PRIMITIVES.md).

## The two histories

| Object | What it records | Where it lives |
| --- | --- | --- |
| Code commit | File changes; optionally one native `context <checkpoint>` header | Ordinary Git branches |
| Context checkpoint | One typed message and its parent checkpoint(s) | `refs/cs/heads/<name>` and other `refs/cs/` refs |

Each checkpoint is a Git commit whose tree contains exactly one file named
`message`. Its parents are the context available before that message. The file
starts with fields such as `kind:`, `id:`, and `from:`, then a blank line and the
message body. Optional `code:` and `path:` fields name the code commit observed
and the relevant files. A code commit's header names the context checkpoint
used to make it; a checkpoint's optional `code:` field names an existing code
commit. One checkpoint and one code commit cannot point to each other, because
each object ID would depend on the other.

The checkpoint's Git object ID changes when its message is replayed onto a
different parent. Its `id:` identifies the same logical message across those
copies. `git cs context` displays effective messages oldest first, once per
logical ID; `git cs show` reads the exact stored message, including one later
superseded or retracted.

## A small collaboration workflow

Use the modified Git binary. From this source checkout, `make` builds it and
`bin-wrappers/git` runs it with the extension on its command path. In the code
repository, create a shared context branch and one branch per contributor:

```sh
git cs init
git cs commit team -m 'Use a stable key format across modules' --kind plan --from lead --code HEAD
git cs branch api team
git cs branch client team
```

The API contributor records a contract before dependent code is complete. The
coordinator selects that one message for the shared branch; the client
contributor then consumes it:

```sh
git cs commit api -m 'lookup(key) returns None for a missing key' --kind contract --from api --path src/api.py
git cs cherry-pick team api
GIT_CS_FROM=client git cs sync client team
git cs context client --last 5
```

`sync` merges the **whole** team history into `client`, then prints unseen
messages from other senders. Its `--path`, `--kind`, and `--from` options filter
the display, not the merged history. To share selectively, put only relevant
checkpoints on `team`, as the coordinator did with `cherry-pick`. For a whole
branch, use `git cs merge team api --retry 10` instead.
`git cs wait client team --from api` repeatedly merges `team` into `client`
until a message from `api` is there, then reports what is new as `sync` does.
An unfiltered `sync` advances that branch's local read cursor; a filtered one
leaves the cursor in place so hidden messages remain available later.

After implementing code, stage it and link the commit to the context used:

```sh
git add src/client.py
git cs commit-code --context client -- -m 'Use the agreed lookup contract'
git cs links --code HEAD
git cs fsck BASE..HEAD
```

Replace `BASE` with the last code commit before context tracking. An unqualified
`fsck` checks all local code branches and will flag older unlinked commits.
`git cs init` sets `commit.requireContext=true` for participating commands of
this modified Git; it also configures existing remotes to fetch context.
Everyone writing code needs that binary or a scoped `fsck` gate: ordinary Git
does not enforce this repository setting.

## Command map

| Need | Commands and behavior |
| --- | --- |
| Record and inspect | `commit` appends one message (`-m` or `-F`); `show` reads exactly one; `context` reads effective history, with `--since`, `--last`, `--kind`, `--from`, and `--path` filters; `log` and `diff` inspect checkpoint history. |
| Organize contributors | `branch` creates a context branch; `switch` binds a local workspace name so `@workspace` resolves to its branch; `tag` fixes one checkpoint; `label` groups exact checkpoints. |
| Share new context | `cherry-pick` copies one checkpoint; `merge` incorporates a branch; `sync` merges and reports unseen messages; `wait` polls for named senders. |
| Revise history | `rebase` copies messages missing from another branch and skips matching logical IDs; `reset` moves a branch; `reflog` and recovery refs retain old tips. `rebase` refuses merge checkpoints. |
| Correct advice | `commit --supersedes <checkpoint>` adds a replacement message; `revert` adds a retraction. Both preserve the original object for audit and change the effective `context` view; neither undoes code. |
| Link and check code | `commit-code` pins context and calls `git commit --context`; `links` follows a code/context link; `fsck` checks reachable checkpoint shape, local `code:` targets, and selected code links. `pin` and `unpin` control checkpoint retention. |
| Transfer | `remote` adds context fetch refspecs; `push` sends context and optional code refs atomically; `fetch` retrieves context; `bundle` packages context refs and selected code refs. |

Parallel writers update context refs conditionally.
`commit --expect <checkpoint>` fails with `STALE_TIP` (exit 75) if another
writer moved the branch; reread its tip before retrying. `merge --retry <n>`
retries that race with backoff.

Context merges do not have file conflicts: each message remains in its own
checkpoint. They can still contain **contradictory advice**. Read both exact
messages with `show`, decide which contract applies, and publish a correction
with `--supersedes` or a retraction. Do not treat a clean context merge as
agreement.

## Sharing with another clone

An ordinary code push alone does not publish `refs/cs/`. Send the context and
code deliberately:

```sh
git cs push origin --context team HEAD:refs/heads/feature
```

On a fresh clone, `git cs remote origin` adds fetch refspecs so later ordinary
`git fetch` and `git pull` bring context, or `git cs fetch origin --context team`
fetches it immediately into `refs/cs/remotes/origin/team`. Fetching context does
not merge it into a personal branch. A receiver can inspect it, then run
`git cs sync client refs/cs/remotes/origin/team` if it is relevant. Fetch the
linked checkpoint before cherry-picking or rebasing a code commit with this
Git binary; otherwise that code operation can fail because its context object
is absent.

`git cs push` without `--context` tries to publish all local context heads,
pins, tags, and labels. A scoped push sends the named heads and pins required
by supplied code refs. A checkpoint's `code:` field does **not** fetch or push
that code commit by itself. `git cs fetch origin --context team --force` can
accept a rewritten remote context head; it saves the previous tracking tip
under `refs/cs/fetch-recovery/origin/team`. This force option is for fetch,
not push. Rebasing a published personal context branch may make a later push
non-fast-forward; coordinate a new branch name or an explicit publication
plan rather than assuming the push will overwrite it.

## Inspecting the context tree

```sh
git for-each-ref --format='%(refname:short) %(objectname:short)' refs/cs/
git log --graph --oneline refs/cs/heads/team
git cs context team --last 10
git cs show <checkpoint>
git cs reflog team
```

The Git graph shows the *stored* checkpoint and merge order; `git cs context`
shows the effective advice after duplicate IDs, supersessions, and retractions
are applied. Use both when investigating what a contributor could have read.

## Current boundaries

- Context is authored and selected manually. A successful fetch or replay
  proves delivery, not that the recipient used the message.
- Context history is separate from code history. A fresh clone needs the CS
  fetch configuration or an explicit `cs fetch`; ordinary system-Git code
  integration can create new commits without the native context header.
- `fsck` requires local code objects named by `code:` fields, so a deliberate
  context-only transfer can report missing code even when the note is intact.
- Rebased checkpoints have new Git IDs; use their stable message `id:` to
  recognize copies. `rebase` skips existing logical IDs, but it cannot replay
  merge checkpoints.
- `--path` keeps pathless messages in the displayed result. It is a relevance
  aid, not an access-control or semantic-conflict mechanism.
