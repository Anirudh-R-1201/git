#!/bin/sh

test_description='commits that name the context checkpoint they were made from'

. ./test-lib.sh

test_expect_success 'setup' '
	test_commit base &&
	git commit-tree -m checkpoint HEAD^{tree} >ctx
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

test_expect_success 'commit --context records the context header' '
	git commit-tree -m other HEAD^{tree} >ctx2 &&
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

test_expect_success 'commit.requireContext refuses commits without a context' '
	test_config commit.requireContext true &&
	test_must_fail git commit --allow-empty -m unlinked 2>err &&
	test_grep "commit.requireContext" err &&
	git commit --allow-empty --context $(cat ctx) -m linked &&
	git commit --amend --allow-empty -m "amend keeps its link"
'

test_expect_success 'commit.requireContext refuses amending an unlinked commit' '
	git commit --allow-empty -m unlinked &&
	test_config commit.requireContext true &&
	test_must_fail git commit --amend --allow-empty -m still-unlinked &&
	git commit --amend --allow-empty --context $(cat ctx) -m now-linked
'

test_done
