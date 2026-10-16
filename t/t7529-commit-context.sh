#!/bin/sh

test_description='commits that name the context checkpoint they were made from'

. ./test-lib.sh

# Print a checkpoint: a commit whose tree holds only a "message" file.
checkpoint () {
	blob=$(printf "kind: message\n\n%s\n" "$1" | git hash-object -w --stdin) &&
	tree=$(printf "100644 blob %s\tmessage\n" $blob | git mktree) &&
	git commit-tree -m "$1" $tree
}

# Print a copy of commit $1 whose context header names $2.
relink () {
	git cat-file commit "$1" |
	sed "s/^context .*/context $2/" |
	git hash-object -t commit -w --stdin
}

test_expect_success 'setup' '
	test_commit base &&
	checkpoint first >ctx
'

test_expect_success 'commit-tree --context records the context header' '
	commit=$(git commit-tree -p HEAD --context $(cat ctx) -m linked HEAD^{tree}) &&
	git cat-file commit $commit >raw &&
	echo "context $(cat ctx)" >expect &&
	grep "^context " raw >actual &&
	test_cmp expect actual &&
	git fsck --strict
'

test_expect_success 'commit-tree without --context writes no header' '
	commit=$(git commit-tree -p HEAD -m plain HEAD^{tree}) &&
	git cat-file commit $commit >raw &&
	! grep "^context " raw
'

test_expect_success 'commit-tree --context rejects names that are not commits' '
	test_must_fail git commit-tree --context HEAD^{tree} -m bad HEAD^{tree} &&
	test_must_fail git commit-tree --context nope -m bad HEAD^{tree}
'

test_expect_success 'commit-tree --context rejects commits that are not checkpoints' '
	test_must_fail git commit-tree --context HEAD -m bad HEAD^{tree} 2>err &&
	test_grep "not a context checkpoint: HEAD" err &&
	blob=$(git rev-parse $(cat ctx):message) &&
	extra=$(printf "100644 blob %s\tmessage\n100644 blob %s\tother\n" $blob $blob | git mktree) &&
	test_must_fail git commit-tree --context $(git commit-tree -m two $extra) -m bad HEAD^{tree} &&
	other=$(printf "100644 blob %s\tnotes\n" $blob | git mktree) &&
	test_must_fail git commit-tree --context $(git commit-tree -m name $other) -m bad HEAD^{tree} &&
	dir=$(printf "040000 tree %s\tmessage\n" $other | git mktree) &&
	test_must_fail git commit-tree --context $(git commit-tree -m dir $dir) -m bad HEAD^{tree} &&
	link=$(printf "120000 blob %s\tmessage\n" $blob | git mktree) &&
	test_must_fail git commit-tree --context $(git commit-tree -m link $link) -m bad HEAD^{tree} &&
	empty=$(git mktree </dev/null) &&
	test_must_fail git commit-tree --context $(git commit-tree -m empty $empty) -m bad HEAD^{tree}
'

test_expect_success 'commit --context records the context header' '
	checkpoint second >ctx2 &&
	test_commit --no-tag one &&
	git commit --allow-empty --context $(cat ctx) -m linked &&
	git cat-file commit HEAD >raw &&
	echo "context $(cat ctx)" >expect &&
	grep "^context " raw >actual &&
	test_cmp expect actual
'

test_expect_success 'commit --amend keeps the context header' '
	git commit --amend --allow-empty -m reworded &&
	git cat-file commit HEAD >raw &&
	grep "^context " raw >actual &&
	test_cmp expect actual
'

test_expect_success 'commit --amend --context replaces it with exactly one header' '
	git commit --amend --allow-empty --no-edit --context $(cat ctx2) &&
	git cat-file commit HEAD >raw &&
	echo "context $(cat ctx2)" >expect &&
	grep "^context " raw >actual &&
	test_cmp expect actual
'

test_expect_success 'commit --context rejects names that are not commits' '
	test_must_fail git commit --allow-empty --context HEAD^{tree} -m bad
'

test_expect_success 'commit --context rejects commits that are not checkpoints' '
	before=$(git rev-parse HEAD) &&
	test_must_fail git commit --allow-empty --context HEAD^ -m bad 2>err &&
	test_grep "not a context checkpoint: HEAD^" err &&
	test_must_fail git commit --allow-empty --amend --context HEAD^ -m bad &&
	test "$(git rev-parse HEAD)" = "$before"
'

test_expect_success 'commit --amend refuses to keep a link to a non-checkpoint' '
	bad=$(relink HEAD $(git rev-parse HEAD^)) &&
	git reset --soft $bad &&
	test_must_fail git commit --amend --allow-empty -m kept 2>err &&
	test_grep "HEAD names a context that is not a checkpoint" err &&
	test "$(git rev-parse HEAD)" = "$bad" &&
	git commit --amend --allow-empty --no-edit --context $(cat ctx) &&
	echo "context $(cat ctx)" >expect &&
	git cat-file commit HEAD >raw &&
	grep "^context " raw >actual &&
	test_cmp expect actual
'

test_expect_success 'commit --amend refuses to keep a link to a missing object' '
	missing=$(test_oid deadbeef) &&
	bad=$(relink HEAD $missing) &&
	git reset --soft $bad &&
	test_must_fail git commit --amend --allow-empty -m kept 2>err &&
	test_grep "not a checkpoint: $missing" err &&
	git commit --amend --allow-empty --no-edit --context $(cat ctx)
'

test_expect_success 'commit.requireContext refuses commits without a context' '
	test_config commit.requireContext true &&
	test_must_fail git commit --allow-empty -m unlinked 2>err &&
	test_grep "commit.requireContext" err &&
	test_must_fail git commit --allow-empty --context HEAD -m code-link &&
	git commit --allow-empty --context $(cat ctx) -m linked &&
	git commit --amend --allow-empty -m "amend keeps its link"
'

test_expect_success 'commit.requireContext refuses amending an unlinked commit' '
	git commit --allow-empty -m unlinked &&
	test_config commit.requireContext true &&
	test_must_fail git commit --amend --allow-empty -m still-unlinked &&
	git commit --amend --allow-empty --context $(cat ctx) -m now-linked
'

context_of () {
	git cat-file commit "$1" | sed -n "s/^context //p"
}

test_expect_success 'setup branches for replay' '
	git checkout -b topic &&
	echo topic >file &&
	git add file &&
	git commit --context $(cat ctx) -m topic-change &&
	git checkout -b other HEAD^ &&
	echo other >other.t &&
	git add other.t &&
	git commit --context $(cat ctx2) -m other-change &&
	git checkout topic
'

test_expect_success 'cherry-pick keeps the picked commit context' '
	git checkout -b pick other &&
	git cherry-pick topic &&
	test "$(context_of HEAD)" = "$(cat ctx)"
'

test_expect_success 'cherry-pick --edit keeps it through git commit' '
	git reset --hard other &&
	GIT_EDITOR=true git cherry-pick --edit topic &&
	test "$(context_of HEAD)" = "$(cat ctx)"
'

test_expect_success 'rebase keeps every replayed commit context' '
	git checkout -b rebased topic &&
	git rebase other &&
	test "$(context_of HEAD)" = "$(cat ctx)" &&
	test "$(context_of HEAD^)" = "$(cat ctx2)"
'

test_expect_success 'resolving a conflicted cherry-pick keeps its context' '
	git checkout -b clash other &&
	echo clash >file &&
	git add file &&
	git commit --context $(cat ctx2) -m clash &&
	test_must_fail git cherry-pick topic &&
	echo resolved >file &&
	git add file &&
	test_config commit.requireContext true &&
	git commit --no-edit &&
	test "$(context_of HEAD)" = "$(cat ctx)"
'

test_expect_success 'revert does not copy the reverted commit context' '
	git revert --no-edit HEAD &&
	test -z "$(context_of HEAD)"
'

test_expect_success 'cherry-pick refuses a commit linked to a non-checkpoint' '
	git checkout -b badpick other &&
	bad=$(relink topic $(git rev-parse other)) &&
	test_must_fail git cherry-pick $bad 2>err &&
	test_grep "names a context that is not a checkpoint" err &&
	test "$(git rev-parse HEAD)" = "$(git rev-parse other)" &&
	test_must_fail git rev-parse -q --verify CHERRY_PICK_HEAD
'

test_expect_success 'rebase stops at a commit linked to a non-checkpoint' '
	git checkout -b badrebase topic &&
	git reset --hard $(relink topic $(git rev-parse other)) &&
	test_must_fail git rebase other 2>err &&
	test_grep "names a context that is not a checkpoint" err &&
	git rebase --abort
'

test_done
