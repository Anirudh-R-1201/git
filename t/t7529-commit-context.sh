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

test_done
