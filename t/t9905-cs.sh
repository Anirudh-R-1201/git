#!/bin/sh

test_description='git cs context histories'

. ./test-lib.sh

kind_of () {
	git cs show "$1" | sed -n "1s/^kind: //p"
}

test_expect_success 'commit -m stores one typed message without touching code' '
	test_commit code &&
	base=$(git cs commit main -m "Investigate SQLite") &&
	test "$(git rev-parse HEAD)" = "$(git rev-parse code)" &&
	git ls-tree --name-only $base >names &&
	echo message >expect &&
	test_cmp expect names &&
	git cs show $base >actual &&
	printf "kind: message\n\nInvestigate SQLite\n" >expect &&
	test_cmp expect actual
'

test_expect_success 'commit takes a kind, an optional code commit and a message file' '
	printf "Use WAL mode\n\nback\\\\slash and \\\\n stay literal\n" >msg &&
	two=$(git cs commit main -F msg --kind learning --code HEAD) &&
	git cs show $two >actual &&
	{
		echo "kind: learning" &&
		echo "code: $(git rev-parse HEAD)" &&
		echo &&
		cat msg
	} >expect &&
	test_cmp expect actual &&
	git log -1 --format=%s $two >subject &&
	echo "learning: Use WAL mode" >expect &&
	test_cmp expect subject
'

test_expect_success 'commit rejects bad kinds, missing code commits and empty messages' '
	test_must_fail git cs commit main -m x --kind "Bad Kind" &&
	test_must_fail git cs commit main -m x --code nope &&
	test_must_fail git cs commit main -m "" &&
	test_must_fail git cs commit "bad..name" -m x 2>err &&
	test_grep "invalid context branch" err
'

test_expect_success 'commit refuses a stale expected tip with exit 75' '
	tip=$(git rev-parse refs/cs/heads/main) &&
	git cs commit main -m three --expect $tip &&
	test_expect_code 75 git cs commit main -m late --expect $tip 2>err &&
	echo STALE_TIP >expect &&
	test_cmp expect err
'

test_expect_success 'context lists every message oldest first' '
	git cs context main | sed "s/^[0-9a-f]* //" >actual &&
	cat >expect <<-\EOF &&
	message: Investigate SQLite
	learning: Use WAL mode

	back\slash and \n stay literal
	message: three
	EOF
	test_cmp expect actual
'

test_expect_success 'log shows one line per checkpoint' '
	git cs log main >log &&
	test_line_count = 3 log &&
	head -n 1 log >top &&
	test_grep "message: three$" top
'

test_expect_success 'checkpoint arguments take context branch names first' '
	git cs branch master $base &&
	test "$(git cs show master)" = "$(git cs show $base)" &&
	git update-ref -d refs/cs/heads/master &&
	test_must_fail git cs show master 2>err &&
	test_grep "not a cs checkpoint" err &&
	test_must_fail git cs reset main HEAD
'

test_expect_success 'diff lists the messages each side has' '
	git cs diff $base main | sed "s/ [0-9a-f]* / /" >actual &&
	printf "+ message: three\n+ learning: Use WAL mode\n" >expect &&
	test_cmp expect actual
'

test_expect_success 'branch, switch, reset and reflog' '
	git cs branch retry $base &&
	test_must_fail git cs branch retry $base &&
	git cs switch -c w1 feat $base &&
	tip=$(git cs commit @w1 -m "via workspace") &&
	test "$(git rev-parse refs/cs/heads/feat)" = $tip &&
	git cs reset feat $base &&
	test "$(git rev-parse refs/cs/recovery/feat)" = $tip &&
	git cs reflog feat >log &&
	test_line_count = 3 log
'

test_expect_success 'tags and labels name exact checkpoints' '
	git cs tag v1 $base &&
	test_must_fail git cs tag v1 main &&
	git cs label add ticket $base main &&
	git cs label resolve ticket >members &&
	test_line_count = 2 members &&
	git cs label remove ticket $base &&
	git cs label resolve ticket >members &&
	test_line_count = 1 members
'

test_expect_success 'merge fast-forwards, reports up to date, or records a merge checkpoint' '
	git cs branch a $base &&
	git cs branch b $base &&
	git cs commit a -m "from a" &&
	git cs commit b -m "from b" &&
	git cs branch ff $base &&
	git cs merge ff a 2>err &&
	echo Fast-forward >expect &&
	test_cmp expect err &&
	git cs merge ff $base 2>err &&
	echo "Already up to date" >expect &&
	test_cmp expect err &&
	m=$(git cs merge a b 2>err) &&
	echo "Merge checkpoint" >expect &&
	test_cmp expect err &&
	test "$(kind_of $m)" = merge &&
	git rev-parse $m^2 &&
	git cs context a | sed "s/^[0-9a-f]* //" | sort >actual &&
	printf "message: Investigate SQLite\nmessage: from a\nmessage: from b\n" >expect &&
	test_cmp expect actual
'

test_expect_success 'merge --no-ff and -m record an explicit merge' '
	git cs branch noff $base &&
	m=$(git cs merge noff b --no-ff -m "take b") &&
	git rev-parse $m^2 &&
	git cs show $m >actual &&
	test_grep "^take b$" actual
'

# Publish six branches into one shared branch at the same time.
publish_in_parallel () {
	for i in 1 2 3 4 5 6
	do
		git cs merge shared "pub$i" --retry 30 >/dev/null &
	done
	wait
}

test_expect_success 'merge --retry lets parallel publishers all land' '
	git cs branch shared $base &&
	for i in 1 2 3 4 5 6
	do
		git cs branch "pub$i" $base &&
		git cs commit "pub$i" -m "p$i" || return 1
	done &&
	publish_in_parallel &&
	git cs context shared | sed "s/^[0-9a-f]* message: //" | grep "^p" | sort >actual &&
	printf "p1\np2\np3\np4\np5\np6\n" >expect &&
	test_cmp expect actual
'

test_expect_success 'rebase replays messages onto the new base and keeps the old tip' '
	git cs branch topic $base &&
	git cs commit topic -m t1 &&
	git cs commit topic -m t2 &&
	old=$(git rev-parse refs/cs/heads/topic) &&
	git cs rebase topic b &&
	git merge-base --is-ancestor refs/cs/heads/b refs/cs/heads/topic &&
	test "$(git rev-parse refs/cs/recovery/topic)" = $old &&
	git cs context topic | sed "s/^[0-9a-f]* message: //" >actual &&
	printf "Investigate SQLite\nfrom b\nt1\nt2\n" >expect &&
	test_cmp expect actual &&
	test_must_fail git cs rebase a $base 2>err &&
	test_grep "cannot replay merge checkpoints" err
'

test_expect_success 'cherry-pick copies one message and revert retracts it' '
	git cs branch pick $base &&
	git cs cherry-pick pick topic &&
	git cs context pick | sed "s/^[0-9a-f]* message: //" >actual &&
	printf "Investigate SQLite\nt2\n" >expect &&
	test_cmp expect actual &&
	git cs revert pick pick &&
	test "$(kind_of pick)" = retract &&
	git cs context pick | sed "s/^[0-9a-f]* message: //" >actual &&
	echo "Investigate SQLite" >expect &&
	test_cmp expect actual
'

test_expect_success 'pin and unpin take context branch names' '
	git cs pin retry &&
	git rev-parse refs/cs/pins/$base &&
	git cs unpin retry &&
	test_must_fail git rev-parse -q --verify refs/cs/pins/$base
'

test_expect_success 'init makes every code commit name its context' '
	git cs init &&
	test "$(git config commit.requireContext)" = true &&
	echo change >file &&
	git add file &&
	test_must_fail git commit -m unlinked &&
	ctx=$(git rev-parse refs/cs/heads/main) &&
	git cs commit-code --context main -- -m linked &&
	test "$(git cs links --code HEAD)" = $ctx &&
	git rev-parse refs/cs/pins/$ctx &&
	git commit --amend -m "still linked" &&
	test "$(git cs links --code HEAD)" = $ctx &&
	test "$(git cs links --context main)" = "$(git rev-parse HEAD)"
'

test_expect_success 'fsck requires exactly one pinned link per code commit' '
	git cs fsck code..HEAD &&
	test_must_fail git cs fsck >out 2>&1 &&
	test_grep "unlinked: $(git rev-parse code)" out &&
	git cat-file commit HEAD >raw &&
	sed "/^context /p" raw >raw2 &&
	two=$(git hash-object -t commit -w raw2) &&
	test_must_fail git cs fsck code..$two >out 2>&1 &&
	test_grep "several links: $two" out &&
	git cs unpin main &&
	test_must_fail git cs fsck code..HEAD >out 2>&1 &&
	test_grep "unpinned link" out &&
	git cs pin main &&
	git update-ref refs/cs/heads/bogus HEAD &&
	test_must_fail git cs fsck code..HEAD >out 2>&1 &&
	test_grep "not a checkpoint: refs/cs/heads/bogus" out &&
	git update-ref -d refs/cs/heads/bogus
'

test_expect_success 'linked context survives branch deletion and gc' '
	ctx=$(git rev-parse refs/cs/heads/main) &&
	git update-ref -d refs/cs/heads/main &&
	git gc --prune=now &&
	git cs show $ctx &&
	git cs branch main $ctx
'

test_expect_success 'push and fetch carry context to a fresh receiver' '
	git init --bare hub.git &&
	git cs push hub.git HEAD:refs/heads/master &&
	git clone hub.git rx &&
	git -C rx cs fetch origin &&
	git -C rx cs show "$(git -C rx cs links --code HEAD)" &&
	git -C rx cs fsck HEAD^..HEAD &&
	git -C rx rev-parse refs/cs/remotes/origin/a refs/cs/tags/v1
'

test_expect_success 'push is atomic across code and context' '
	git push -f hub.git "$(git commit-tree HEAD^{tree} -m other)":refs/heads/master &&
	before=$(git -C hub.git rev-parse refs/cs/heads/a) &&
	git cs commit a -m newer &&
	test_must_fail git cs push hub.git HEAD:refs/heads/master &&
	test "$(git -C hub.git rev-parse refs/cs/heads/a)" = $before
'

test_expect_success 'bundle carries context offline' '
	git cs bundle cs.bundle HEAD &&
	git init offline &&
	git -C offline fetch ../cs.bundle "refs/cs/*:refs/cs/*" HEAD:refs/heads/in &&
	git -C offline cs show "$(git -C offline cs links --code in)"
'

test_expect_success 'no temporary files are left behind' '
	test_path_is_missing .git/cs-tmp.*
'

test_done
