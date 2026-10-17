# ContextShadow primitives on `kaizen`

This describes the implementation on the `kaizen` branch as of 2026-10-17:
the 2026-10-16 work (stable message IDs, native links on every commit path)
combined with the changes made after the parallel-agent benchmark report
(see [DESIGN-NOTES.md](DESIGN-NOTES.md)). The command reference is
[git-cs(1)](../Documentation/git-cs.adoc); the implementation is
[`git-cs.sh`](../git-cs.sh) plus the native Git changes cited below.

## What the system is for

ContextShadow lets a coding team publish the decisions a code change depends
on before, during and after the change. For example, one agent can publish an
API contract as a `learning`, another can read it without seeing the first
agent's code branch, and each code commit can name the exact context checkpoint
used to make it. Context moves through its own branches and can be transferred
with the code. The system records messages supplied by its users; it does not
capture conversations or tool output automatically.

The separate histories serve different questions:

* A **code commit** answers what files changed. Its native `context <object-id>`
  header points to one checkpoint.
* A **context checkpoint** answers what message was recorded at that point.
  Its ancestors provide the context available then. An optional `code:` field
  identifies the code commit the message was captured against, which can be an
  earlier code commit. It cannot point back to a code commit that points to the
  same checkpoint: both object IDs would depend on each other.

## Storage and identity

A checkpoint is a Git commit with a tree containing exactly one regular file,
`message`. A normal checkpoint has one parent (or none for a new context
branch); a context merge checkpoint has two. The file contains `kind:`, a
random 128-bit `id:`, the sender in `from:`, an optional `code:`, any number
of `path:` lines, a blank line and the message body. A retraction also has
`retracts: <message-id>`, and a correction `supersedes: <message-id>`. The message ID survives context
cherry-pick and rebase because those operations copy the message tree. It
identifies one logical message across copies; the Git checkpoint IDs still
differ. See [`git-cs.sh`](../git-cs.sh) `write_message`, `checkpoint`, and
`replay`.

The native commit link is a header in the commit object, not a commit-message
trailer. Git accepts a target as a checkpoint when its tree has exactly the
one regular `message` file. This structural check does not prove that the
message body is true or that all of its fields are well formed. See
[`commit.c`](../commit.c) `repo_is_context_checkpoint` and
`repo_keep_context`.

| Ref | Role |
|---|---|
| `refs/cs/heads/<name>` | Movable context branch. |
| `refs/cs/workspaces/<name>` | Symbolic ref selecting a branch for `@<name>`; local only. |
| `refs/cs/recovery/<name>` | Previous tip saved by context `reset` or `rebase`. |
| `refs/cs/tags/<name>` | Fixed name for one checkpoint. |
| `refs/cs/labels/<name>/<id>` | One exact checkpoint in a named group. |
| `refs/cs/pins/<checkpoint>` | Keeps a linked checkpoint reachable for garbage collection. |
| `refs/cs/remotes/<remote>/<name>` | Context branch fetched from a remote. |
| `refs/cs/seen/<name>` | Read cursor kept by `sync` and `wait`; its reflog records when new messages were read. Local only. |

## `git cs` primitives

| Primitive | What it does | How it works |
|---|---|---|
| `init` | Requires context for new code commits made through participating Git commands, and makes ordinary fetches bring context. | Sets local `commit.requireContext=true`; those paths enforce it and pin links they write. Plumbing `commit-tree` can still write an unlinked commit. Runs `remote` for every configured remote. |
| `remote <name>` | Lets plain `git fetch` and `git pull` bring context. | Adds `refs/cs/` fetch refspecs to `remote.<name>.fetch`; running it again adds nothing. |
| `commit <branch> -m/-F ...` | Adds one typed message, optionally tied to existing code with `--code`, naming the files it concerns with `--path`, or replacing an earlier message with `--supersedes`. | Writes the `message` blob and a one-file tree, creates a checkpoint on the branch tip, then conditionally updates its ref. The sender comes from `--from`, `GIT_CS_FROM`, `cs.from` or the author name. `--expect` takes a checkpoint or context branch name; a lost race prints `STALE_TIP` and exits 75. |
| `show <checkpoint>` | Reads one message. | Reads `<checkpoint>:message`. Context branch names take precedence over same-named code refs. |
| `context <checkpoint>` | Shows the effective messages available at a checkpoint. | Reads every ancestor message in one `cat-file --batch` pass, oldest first, printing `<checkpoint> <from> <kind>: <body>` once per message ID; excludes merge records, retractions, and every copy of a retracted or superseded message ID. `--since`, `--last`, `--kind`, `--from` and `--path` narrow the output. |
| `sync <me> <team>` | Catches up in one call. | Merges the team branch into `<me>`, prints only messages from others that `<me>` gained since its last sync, and moves `refs/cs/seen/<me>`. |
| `wait <me> <team> --from <names>` | Blocks until named senders have published. | Syncs every two seconds until each sender has a message (optionally of a kind), then prints what is unseen as `sync` does; messages already seen are not repeated. Fails after a timeout naming who is missing. |
| `log`, `diff` | Inspects checkpoint history or checkpoints unique to each side. | Uses Git log/revision walks over context commits. `diff` compares history membership, not a file snapshot. |
| `branch`, `switch` | Starts a context branch; associates a named workspace with one. | Writes `refs/cs/heads/*` or a symbolic `refs/cs/workspaces/*` ref. `@workspace` resolves to the selected branch. |
| `reset`, `reflog` | Moves a context branch or inspects its old tips. | Saves the prior tip in a recovery ref before the move; context branch updates use reflogs. |
| `tag`, `label` | Names one checkpoint immutably or groups exact checkpoints. | Uses `refs/cs/tags/*` with create-only updates, or one `refs/cs/labels/*` ref per member. |
| `merge` | Publishes another context history. | Fast-forwards when possible; otherwise writes a two-parent `merge` checkpoint. Messages remain in their own ancestor checkpoints, so there is no message-file conflict to resolve. `--retry` retries lost ref races with randomized backoff. |
| `rebase`, `cherry-pick` | Copies context messages onto another history. | Reuses each message tree and its stable `id` in new checkpoint commits. Context rebase does nothing when the branch already contains the target, fast-forwards when the target contains it, refuses merge checkpoints, and saves the old tip. |
| `revert` | Retracts a context message from the effective context. | Appends a `retract` checkpoint naming the message ID. It hides all copies of that ID reached by the branch; it does not reverse code or tool effects. Merge and retract checkpoints cannot be retracted. |
| `pin`, `unpin` | Retains or releases a checkpoint independently of branches. | Creates or deletes `refs/cs/pins/<checkpoint>`. Unpinning a linked checkpoint can make `fsck` report an unpinned link. |
| `commit-code --context` | Creates a linked code commit through `git cs`. | Resolves and pins the checkpoint, then calls native `git commit --context`. It also pins when `commit.requireContext` is off. |
| `links --code/--context` | Follows a link in either direction. | Reads the code commit header directly; the reverse direction scans selected code refs, defaulting to all code branches. |
| `fsck [<code-revs>...]` | Reports broken context refs and code links. | Checks that `refs/cs/*` targets have checkpoint shape and a nonempty `id`, and that the `code:` field of every checkpoint reachable from them names a commit present locally. For selected code commits (all branches by default), it checks for exactly one link, to a pinned checkpoint, and names links to non-checkpoints. |
| `push`, `fetch`, `bundle` | Transfers context with code. | Pushes context heads, pins, tags and labels plus supplied code refspecs atomically, or with `--context <branch>` only the chosen branches and the pins the pushed code links to; fetches remote context heads into `refs/cs/remotes/*` and the other shared refs directly; or writes those refs and supplied code refs to a bundle. Workspaces and recovery refs are not included. |

## Native code-commit primitives

| Primitive | Behavior at this tip |
|---|---|
| `git commit --context <checkpoint>` | Writes one native `context` header. `--amend` keeps the previous link unless replaced. With `commit.requireContext=true`, an unlinked commit is refused and a linked checkpoint is pinned. A plain `git commit --context` with the setting off does not pin it. See [`builtin/commit.c`](../builtin/commit.c). |
| `git commit-tree --context <checkpoint>` | Plumbing equivalent for the header; pins a supplied link when the setting is on. The setting does **not** make `--context` mandatory for `commit-tree`. See [`builtin/commit-tree.c`](../builtin/commit-tree.c). |
| `git merge --context <checkpoint>` | Links a merge commit if one is created. With the requirement on and no `--context`, a merge needing a commit stops before committing with a nonzero status; finish with `git commit --context`. A fast-forward creates no new commit. See [`builtin/merge.c`](../builtin/merge.c). |
| `git cherry-pick`, `git rebase` | Replay each source code commit's validated link, including hand-resolved picks; `--rebase-merges` keeps a recreated merge's link and `--apply` keeps the original patch commit's link. When a required link is absent, the operation stops so one can be supplied. See [`sequencer.c`](../sequencer.c) and [`builtin/am.c`](../builtin/am.c). |
| `git am --context <checkpoint>` | Applies one supplied checkpoint to each patch-created commit. With the requirement on, `am` refuses to start without it. See [`builtin/am.c`](../builtin/am.c). |
| `git replay` / `git revert` | Replay preserves and checks a source code commit's link. A replayed revert omits that link and fails when a link is required. Ordinary `git revert` also omits the reverted commit's link and stops for a newly linked commit when the requirement is on. See [`replay.c`](../replay.c) and [`sequencer.c`](../sequencer.c). |

## Practical sequence

1. Start with a code repository, then run `git cs init` and record a team brief
   with `git cs commit team -m '...' --kind plan --code HEAD`.
2. Give each contributor a context branch (`git cs branch agent team`) and a
   sender name (`GIT_CS_FROM=agent`). Publish a decision or contract there,
   with `--path` for the files it concerns, before dependent code is written,
   and merge it into the shared context with `git cs merge team agent --retry 10`.
   Others catch up with `git cs sync <their-branch> team`, or block with
   `git cs wait <their-branch> team --from agent`.
3. Commit code with `git cs commit-code --context agent -- -m '...'`, or use
   native `git commit --context <checkpoint>`. A code merge can use
   `git merge --context <checkpoint>`.
4. Check new code commits with `git cs fsck BASE..HEAD` (replace `BASE` with the
   last code commit before context tracking), then use
   `git cs push <remote> [--context <branch>] <code-refspec>` to send code and
   context together. Receivers run `git cs remote <remote>` once (or
   `git cs init`), after which ordinary `git fetch` and `git pull` bring the
   context refs.

The range in step 4 matters when a project has older, unlinked commits:
unqualified `git cs fsck` checks all code branches and will flag them. The
check confirms link structure and retention for the selected commits; it
does not check whether a message accurately describes the work.

All code writers need the modified Git binary for creation-time enforcement.
`git cs init` only sets repository config: in an independent check, stock
Apple Git 2.54.0 ignored `commit.requireContext=true` and wrote an unlinked
commit. The modified binary's `git cs fsck` detected it. Teams using mixed
Git installations can run scoped `git cs fsck` over incoming code commits
before accepting them.

## Verification at this tip

A forced `make -B -j8` completed and the binary reports `git version 2.56.GIT`.
`t/t9905-cs.sh` passed 47/47 and `t/t7529-commit-context.sh` 47/47, each
twice; `cs-testing/cmdtable.sh` passed 58/58. The full Git shell suite
completed 1,063 scripts with 32,706 successes, zero failures and 375 expected
breakages, and the C unit target passed 261/261. Three agents then shared all
nine messages through `sync` and `wait`, every code commit carried one pinned
link, and a fresh clone resolved 6/6 links. See [RESULTS.md](RESULTS.md),
which also keeps the 2026-10-16 independent checks and the two-agent `ledger`
project.
