# `git cs` test results

Run on 2026-10-16 against the `kaizen` branch at
`8d632c30b5454c1a6d56d14f8347d9b6bc5bf3af`, verified against the remote
branch before testing. Built with `make -j8`, then forcibly rebuilt with
`make -B -j8 git git-cs`, and used through `bin-wrappers/`
(`git version 2.56.GIT`). Rerun with the commands in [README.md](README.md).
The implementation and use case are detailed in [PRIMITIVES.md](PRIMITIVES.md).
Design decisions are in [DESIGN-NOTES.md](DESIGN-NOTES.md).
The working tree also contains the test-only lint fixes, the example helper
timeout fix, and the `git cs --help-all` fix described below; it has not been
committed.

## Summary

| Suite | Result |
|---|---|
| Full Git shell suite | `make -k -j12 test`: 1,063 scripts; 32,696 successful checks, 0 failures, 375 known breakages, 827 skipped, 33,898 total |
| C unit suite | `make -C t unit-tests`: 261/261 |
| `t/t9905-cs.sh` | 35/35 |
| `t/t7529-commit-context.sh` | 47/47 |
| `cs-testing/cmdtable.sh` | 45/45 |
| Independent fresh-repository scenarios | Context publication, native merge, push/fetch, link retention and scoped `fsck` passed; unlinked commits from plumbing and stock Git were reported by `fsck` |
| Three-agent `textstats` project | 9/9 agent messages published, context rebases read teammates' learnings, merged Python tests 6/6, fresh clone resolved 6/6 code links |
| Two-agent `ledger` project | Superseded parser learning retracted; summary rebase saw corrected contract only; merged Python tests 3/3, fresh clone resolved 5/5 code links |

## Full-suite path

The first `make test` attempt stopped at the test lint gate: four negated bare
`grep` calls in `t9905-cs.sh` and `t7529-commit-context.sh` needed the test
harness's `test_grep !` form. These assertions were changed without altering
what they check.

The next sandboxed attempt failed all nine cases in `t0052-simple-ipc.sh`
because its local daemon terminated. The same test passed 9/9 with local IPC
access outside the sandbox. An unrestricted full run then found a real
ContextShadow integration bug: `git cs --help-all` failed outside a repository
in `t1517-outside-repo.sh`. `git-cs.sh` now normalizes `--help-all` to `-h`
before `git-sh-setup` asks for a repository. The focused outside-repository
suite passed after that change.

The final run, `make -k -j12 test`, exited 0. Its aggregate reported
`success 32696`, `failed 0`, `broken 375`, `total 33898`; the remaining 827
checks were skipped. All 1,063 shell scripts ran. Git marks those 375 as
existing expected breakages. The separate
C unit target exited 0 with 261 passing checks. `cs-testing/cmdtable.sh` was
rerun against the final script and passed 45/45.

## Independent checks

All checks used new repositories under `/tmp`, separate from Git's scripted
test repositories. The first two used the built `bin-wrappers/git`.

* Two context branches published a `learning` and a `review` message to a
  team context branch. A code commit's single `context` header matched the
  team checkpoint and its pin. An atomic push to a bare remote followed by a
  clone and `git cs fetch` made the link resolvable; scoped `git cs fsck`
  passed in the sender and receiver.
* After the forced rebuild, separate feature and main code commits both
  linked to a brief checkpoint. Native `git merge --no-ff --no-edit --context`
  wrote a merge commit linked to a later decision checkpoint. Its pin existed,
  and scoped `git cs fsck` passed before and after push, clone and context
  fetch. With `commit.requireContext=true`, a direct `git commit-tree` without
  `--context` also succeeded; after its ID was placed on a code branch,
  `git cs fsck` reported that commit as `unlinked`. This is the plumbing
  enforcement limit described in [PRIMITIVES.md](PRIMITIVES.md).
* In a third repository, `git cs init` set `commit.requireContext=true`, but
  stock Apple Git 2.54.0 still wrote an unlinked code commit. The built
  binary's `git cs fsck` reported it as `unlinked`. Creation-time enforcement
  therefore depends on using this forked Git binary.

## Primitives

| Primitive | What it does | How it does it |
|---|---|---|
| `git commit --context <ckpt>` | Records which checkpoint a code commit was made from | Writes a `context <id>` header into the commit object; `--amend` keeps it unless replaced; with `commit.requireContext` set, pins it |
| `git commit-tree --context <ckpt>` | Same, for plumbing | Same header through `commit_tree_extended`; pins if required, but `commit-tree` can still make an unlinked commit |
| `commit.requireContext` | Makes links mandatory for normal code-commit paths | `git commit` refuses an unlinked commit; cherry-pick, rebase, `am`, replay and merge stop or refuse as appropriate; linked commits pin their checkpoints |
| `git cherry-pick` / `git rebase` | Keep each replayed commit's link | The sequencer and apply backend validate and copy source links; a hand-resolved conflict inherits one; recreated merges retain theirs |
| `git merge --context` / `git am --context` | Link merges and applied patches | Merge links a new merge commit; without a required context it stops before committing. `am` assigns one supplied checkpoint to each new commit |
| `git replay` / `git revert` | Replay links or require a new one for a revert | Replay validates and preserves a source link; reverts do not inherit the reverted commit's link |
| `git cs init` | Turns the requirement on | Sets `commit.requireContext=true` in the repository config |
| `git cs commit <branch> -m <msg> [--kind k] [--code c]` | Records one message as a checkpoint | Writes a `message` blob (`kind:`, stable `id:`, optional `code:`, blank line, body) in a one-file tree; `commit-tree` on the tip; conditional `update-ref` (`STALE_TIP`, exit 75, on a lost race) |
| `git cs show <ckpt>` | Prints one typed message | `cat-file` of the `message` blob |
| `git cs context <ckpt>` | The effective context at a point | Ancestors oldest first; duplicate IDs, merges, retractions and retracted messages left out |
| `git cs log <ckpt>` / `diff <a> <b>` | History, or what each side has | `git log` over checkpoints whose subjects are `<kind>: <first line>` |
| `git cs branch` / `switch` / `reset` / `reflog` | Branch anywhere, per-workspace selection, safe moves | Refs under `refs/cs/heads/`, symbolic refs under `refs/cs/workspaces/`, recovery refs and reflogs |
| `git cs tag` / `label` | Name one checkpoint, or group many | `refs/cs/tags/`, `refs/cs/labels/<name>/<id>` |
| `git cs merge [--no-ff] [-m] [--retry n]` | Combines histories | Fast-forward, or a two-parent checkpoint of kind `merge`; no message-file conflict; retries lost ref races with jittered backoff |
| `git cs rebase` / `cherry-pick` | Pull teammates' context into a branch | Copies each message tree and stable ID onto the new base; merges refused by rebase |
| `git cs revert` | Hides a logical message | Records a `retract` checkpoint with `retracts: <id>`, hiding every copy of that ID |
| `git cs pin` / `unpin` | Keeps context safe from GC | `refs/cs/pins/<id>` |
| `git cs commit-code --context <ckpt>` | Linked code commit in one step | Pins, then `git commit --context` |
| `git cs links --code` / `--context` | Follow a link either way | Reads the header; the reverse scans code refs |
| `git cs fsck [<revs>]` | Finds broken links | Every `refs/cs/` ref is a checkpoint with a nonempty `id` and an existing `code` commit if named; each selected code commit has exactly one pinned `context` header |
| `git cs push` / `fetch` / `bundle` | Transfer | Atomic push of context and code refs; fetch into `refs/cs/remotes/`; bundles |

## Per-command results

Generated by `cs-testing/cmdtable.sh`.

| cmd | testing example done | expected outcome | received outcome | result |
|---|---|---|---|---|
| commit -m | `git cs commit main -m 'Investigate SQLite'` | tree=message code_head_moved=no worktree_clean=yes | tree=message code_head_moved=no worktree_clean=yes | PASS |
| show | `git cs show main` | kind: message  Investigate SQLite | kind: message  Investigate SQLite | PASS |
| commit --kind --code | `git cs commit main -m 'Use WAL mode' --kind learning --code HEAD` | kind=learning code=HEAD subject=learning: Use WAL mode | kind=learning code=HEAD subject=learning: Use WAL mode | PASS |
| commit -F (escapes) | `git cs commit esc -F msg  (body with \n and \\)` | bytes_equal=yes | bytes_equal=yes | PASS |
| commit --expect (stale) | `git cs commit main -m late --expect <old tip>` | exit=75 stderr=STALE_TIP tip_unchanged=yes | exit=75 stderr=STALE_TIP tip_unchanged=yes | PASS |
| commit (invalid input) | `bad kind / --code nope / empty message` | bad_kind=refused bad_code=refused empty=refused | bad_kind=refused bad_code=refused empty=refused | PASS |
| context | `git cs context main` | message: Investigate SQLite|learning: Use WAL mode|message: newer | message: Investigate SQLite|learning: Use WAL mode|message: newer | PASS |
| log | `git cs log main` | 3 lines, newest=message: newer | 3 lines, newest=message: newer | PASS |
| show (bare name) | `git cs show main  (code branch main also exists)` | resolves_to=context | resolves_to=context | PASS |
| diff | `git cs diff <base> main` | + message: newer + learning: Use WAL mode | + message: newer + learning: Use WAL mode | PASS |
| branch | `git cs branch agent-a <base>; again` | created_at_base=yes second=refused | created_at_base=yes second=refused | PASS |
| switch | `git cs switch -c w1 wb <base>; git cs commit @w1 -m hi` | workspace=refs/cs/heads/wb context=message: Investigate SQLite|message: hi | workspace=refs/cs/heads/wb context=message: Investigate SQLite|message: hi | PASS |
| reset | `git cs reset wb <base>` | tip=base recovery=old_tip | tip=base recovery=old_tip | PASS |
| reset (code commit) | `git cs reset wb HEAD` | refused=yes stderr=not a cs checkpoint: HEAD | refused=yes stderr=not a cs checkpoint: HEAD | PASS |
| reflog | `git cs reflog wb` | entries=3 | entries=3 | PASS |
| tag | `git cs tag v1 main; git cs tag v1 <base>` | created=yes move_refused=yes | created=yes move_refused=yes | PASS |
| label | `git cs label add sprint <base> main; remove sprint <base>` | after_add=2 after_remove=1 | after_add=2 after_remove=1 | PASS |
| merge (fast-forward) | `git cs merge ff agent-a` | stderr=Fast-forward tip=agent-a | stderr=Fast-forward tip=agent-a | PASS |
| merge (up to date) | `git cs merge ff <base>` | stderr=Already up to date printed=current_tip | stderr=Already up to date printed=current_tip | PASS |
| merge (checkpoint) | `git cs merge agent-a agent-b` | stderr=Merge checkpoint kind=merge parents=2 context=message: Investigate SQLite|message: from a|message: from b | stderr=Merge checkpoint kind=merge parents=2 context=message: Investigate SQLite|message: from a|message: from b | PASS |
| merge --no-ff -m | `git cs merge noff agent-b --no-ff -m 'take b'` | parents=2 body=take b | parents=2 body=take b | PASS |
| merge (8 parallel, no --retry) | `8x: git cs merge s0 q0-N &` | landed=1/8 exit75=7 | landed=1/8 exit75=7 | PASS |
| merge --retry (8 parallel) | `8x: git cs merge s20 q20-N --retry 20 &` | landed=8/8 exit0=8 | landed=8/8 exit0=8 | PASS |
| commit (8 parallel, same tip) | `8x: git cs commit race -m rN --expect <tip> &` | succeeded=1 exit75=7 | succeeded=1 exit75=7 | PASS |
| rebase | `git cs rebase topic agent-b` | context=message: Investigate SQLite|message: from b|message: t1|message: t2 recovery=old_tip | context=message: Investigate SQLite|message: from b|message: t1|message: t2 recovery=old_tip | PASS |
| rebase (merge checkpoints) | `git cs rebase agent-a <base>` | refused=yes stderr=cannot replay merge checkpoints | refused=yes stderr=cannot replay merge checkpoints | PASS |
| cherry-pick | `git cs cherry-pick pick topic` | context=message: Investigate SQLite|message: t2 | context=message: Investigate SQLite|message: t2 | PASS |
| revert | `git cs revert pick pick` | kind=retract context=message: Investigate SQLite | kind=retract context=message: Investigate SQLite | PASS |
| pin / unpin | `git cs pin topic; git cs unpin topic` | pinned=yes unpinned=yes | pinned=yes unpinned=yes | PASS |
| init | `git cs init; git commit -m unlinked` | requireContext=true plain_commit=refused | requireContext=true plain_commit=refused | PASS |
| commit-code | `git cs commit-code --context main -- -m 'Add x'` | header=main pinned=yes headers=1 | header=main pinned=yes headers=1 | PASS |
| git commit --amend | `git commit --amend -m reworded` | link_kept=yes | link_kept=yes | PASS |
| git commit --amend --context | `git commit --amend --context agent-b ...  (via full id)` | header=agent-b headers=1 | header=agent-b headers=1 | PASS |
| links --code | `git cs links --code HEAD` | main | main | PASS |
| links --context | `git cs links --context main` | HEAD | HEAD | PASS |
| git cherry-pick (code) | `git cherry-pick side  (side commit linked to agent-b)` | link=agent-b | link=agent-b | PASS |
| git rebase (code) | `git rebase main side` | link=agent-b | link=agent-b | PASS |
| fsck | `git cs fsck <base>..main; git cs fsck` | range=clean full=flags_unlinked_root | range=clean full=flags_unlinked_root | PASS |
| gc survival | `delete branch main; git gc --prune=now; git cs show <main>` | readable=yes | readable=yes | PASS |
| push | `git cs push origin main` | pushed=yes remote_has_context=yes | pushed=yes remote_has_context=yes | PASS |
| push (atomic refusal) | `remote main diverged; git cs push origin main` | refused=yes remote_context_unchanged=yes | refused=yes remote_context_unchanged=yes | PASS |
| fetch | `git clone hub rx; git cs fetch origin` | links_resolve=yes fsck=clean | links_resolve=yes fsck=clean | PASS |
| bundle | `git cs bundle ctx.bundle main; fetch into empty repo` | links_resolve=yes | links_resolve=yes | PASS |
| no JSON | `grep jq in the installed git-cs` | jq_calls=0 | jq_calls=0 | PASS |
| temp files | `ls .git after all runs` | left=0 | left=0 | PASS |

## Parallel agents

Three agents (alpha: tokenizer, beta: `top_words` built on alpha's tokenizer,
gamma: tests written only from the published contracts) ran concurrently in
separate code worktrees using [agents/PROMPT.md](agents/PROMPT.md). They were
instructed to read teammates' decisions only from `git cs`, and `git cs init`
made code links mandatory. The agents published to a shared context branch,
rebased their own context branches onto it, and committed code on separate
code branches. The verifier merged their code with linked merge commits.

| Check | Expected | Received |
|---|---|---|
| Messages on the team context | 2 brief + 3 per agent | 11 messages, 18 checkpoints, 7 merges |
| Each agent's messages reached `main` | 3 each | alpha 3, beta 3, gamma 3 |
| Publish outcomes | exit 0, outcome reported | Fast-forward or Merge checkpoint, all exit 0, no `git cs` errors |
| Every code commit names its context | one `context` header each | 3 agent commits and 3 merge commits, one header each |
| Links pinned | `fsck` clean | clean per agent and for all agent and merge commits |
| Tests on merged code | pass | 6/6 `unittest` tests passed |
| Fresh clone after `cs push` / `cs fetch` | every link resolves | 6/6, tests OK |

Gamma's tests could not run in gamma's isolated code worktree because alpha's
and beta's modules were intentionally absent there. They passed after the
code branches were merged. Context carried the contracts; code integration
was still required.

The second project, `ledger`, used two more agents in separate worktrees.
The parser agent first published a `v1` API learning, retracted it by message
ID, and published a corrected `v2` contract. The summary agent rebased its
context branch, verified that `v2` was visible and `v1` was hidden, then
implemented against the corrected contract without reading parser code. The
integrator merged both code branches with native `git merge --context`, added
linked contract tests, and transferred code and context to a fresh clone.

| Check | Received |
|---|---|
| Effective team context | 7 messages across 12 checkpoints and 3 context merges; the one retracted `v1` message is hidden |
| Summary branch after rebase | Parser `v2` visible; parser `v1` absent |
| Agent code links | Parser and summary code commits linked and scoped `fsck` clean |
| Merged project | 3/3 `unittest` tests passed; scoped `fsck` clean |
| Fresh clone | 5/5 new code links resolved, 3/3 tests passed, scoped `fsck` clean |

The parser agent initially ran `git cs fsck <parser-commit>` and saw the
unlinked pre-context skeleton commit in that commit's ancestry. Using
`git cs fsck <pre-context-base>..parser` passed; the initial failure was a
revision-scope issue, not a broken parser link.

After these runs, source review found that the `cs-wait` example helper could
exhaust its wait loop and still return success with a missing learning. It now
exits nonzero with the missing agent's name. A one-iteration fixture checked
both the present-learning success and missing-learning timeout paths. The live
agent runs had already received their required learnings, verified separately
from the helper's exit status.

## Known gaps

| Gap | Seen in | Impact |
|---|---|---|
| `log` and `context` interleave teammates' messages and merge entries | agents | Expected for a shared history; filter by the agent prefix |
| Writing the kind in the message text repeats it in subjects | agents | Cosmetic; the kind is already a field |
| `links` and `branch` print bare IDs or nothing | agents | Cosmetic |
| `git cs --help` had no installed manual entry in the agent checkout | textstats agent | `git cs -h` and `git cs --help-all` work; building/installing the manual was not tested |
| The `context` header is not converted between SHA-1 and SHA-256 in repositories using both | Source review of `convert_commit_extra_headers`; not exercised in this run | Affects hash-interop repositories |
