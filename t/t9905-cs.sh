#!/bin/sh

test_description='git cs context histories'

. ./test-lib.sh

kind_of () {
	git cs show "$1" | sed -n "1s/^kind: //p"
}

id_of () {
	git cs show "$1" | sed -n "/^\$/q; s/^id: //p"
}

# The message without its random id line.
show_without_id () {
	git cs show "$1" | sed "/^id: [0-9a-f]\{32\}\$/d"
}

test_expect_success 'commit -m stores one typed message without touching code' '
	test_commit code &&
	base=$(git cs commit main -m "Investigate SQLite") &&
	test "$(git rev-parse HEAD)" = "$(git rev-parse code)" &&
	git ls-tree --name-only $base >names &&
	echo message >expect &&
	test_cmp expect names &&
	git cs show $base | sed -n 2p >id &&
	test_grep "^id: [0-9a-f]\{32\}\$" id &&
	show_without_id $base >actual &&
	printf "kind: message\n\nInvestigate SQLite\n" >expect &&
	test_cmp expect actual
'

test_expect_success 'commit takes a kind, an optional code commit and a message file' '
	printf "Use WAL mode\n\nback\\\\slash and \\\\n stay literal\n" >msg &&
	two=$(git cs commit main -F msg --kind learning --code HEAD) &&
	show_without_id $two >actual &&
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

test_expect_success 'every message gets its own id, even with the same text' '
	a=$(git cs commit ids -m same) &&
	b=$(git cs commit ids -m same) &&
	test -n "$(id_of $a)" &&
	test "$(id_of $a)" != "$(id_of $b)"
'

test_expect_success 'commit refuses the kinds git cs records itself' '
	test_must_fail git cs commit main -m x --kind merge 2>err &&
	test_grep "reserved" err &&
	test_must_fail git cs commit main -m x --kind retract
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

test_expect_success 'a code commit with a message directory is not a checkpoint' '
	git init fake &&
	mkdir fake/message &&
	echo code >fake/message/file &&
	git -C fake add message &&
	git -C fake commit -m code &&
	test_must_fail git -C fake cs show HEAD
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

test_expect_success 'rebase keeps retractions of replayed messages' '
	git cs branch retract-topic $base &&
	learning=$(git cs commit retract-topic -m "obsolete learning" --kind learning) &&
	git cs revert retract-topic "$learning" &&
	git cs rebase retract-topic b &&
	git cs context retract-topic >actual &&
	test_grep "from b" actual &&
	! grep "obsolete learning" actual
'

test_expect_success 'copies keep the id, so a retraction hides every copy' '
	git cs branch id-src $base &&
	learning=$(git cs commit id-src -m "picked learning" --kind learning) &&
	retraction=$(git cs revert id-src "$learning") &&
	git cs branch id-pick $base &&
	copy=$(git cs cherry-pick id-pick "$learning") &&
	test "$(id_of $copy)" = "$(id_of $learning)" &&
	git cs context id-pick >actual &&
	test_grep "picked learning" actual &&
	git cs cherry-pick id-pick "$retraction" &&
	git cs context id-pick >actual &&
	! grep "picked learning" actual
'

test_expect_success 'a merged retraction hides a copy picked earlier' '
	git cs branch id-merge $base &&
	git cs cherry-pick id-merge "$learning" &&
	git cs merge id-merge id-src --no-ff &&
	git cs context id-merge >actual &&
	! grep "picked learning" actual
'

test_expect_success 'a message that reaches a branch twice is shown once' '
	git cs branch id-twice $base &&
	kept=$(git cs commit id-twice -m "kept learning" --kind learning) &&
	git cs branch id-twice-pick $base &&
	git cs cherry-pick id-twice-pick "$kept" &&
	git cs merge id-twice id-twice-pick --no-ff &&
	git cs context id-twice >actual &&
	grep -c "kept learning" actual >count &&
	echo 1 >expect &&
	test_cmp expect count
'

test_expect_success 'retracting one of two identical messages keeps the other' '
	git cs branch id-same $base &&
	first=$(git cs commit id-same -m "same text" --kind learning) &&
	git cs commit id-same -m "same text" --kind learning &&
	git cs revert id-same "$first" &&
	git cs context id-same >actual &&
	grep -c "same text" actual >count &&
	echo 1 >expect &&
	test_cmp expect count
'

test_expect_success 'revert refuses merge and retract checkpoints' '
	test_must_fail git cs revert id-same id-same 2>err &&
	test_grep "cannot retract a retract checkpoint" err &&
	test_must_fail git cs revert id-merge id-merge 2>err &&
	test_grep "cannot retract a merge checkpoint" err
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

test_expect_success 'fsck reports a link to a commit that is not a checkpoint' '
	git cat-file commit HEAD >raw &&
	sed "s/^context .*/context $(git rev-parse code)/" raw >raw2 &&
	bad=$(git hash-object -t commit -w raw2) &&
	test_must_fail git cs fsck code..$bad >out 2>&1 &&
	test_grep "link to non-checkpoint: $bad -> $(git rev-parse code)" out &&
	test_grep ! "unpinned link: $bad" out
'

test_expect_success 'fsck reports checkpoints without an id' '
	git cs show main | sed "/^id: /d" >noid &&
	tree=$(printf "100644 blob %s\tmessage\n" $(git hash-object -w noid) | git mktree) &&
	git update-ref refs/cs/heads/noid $(git commit-tree -m noid $tree) &&
	test_must_fail git cs fsck code..HEAD >out 2>&1 &&
	test_grep "missing id: refs/cs/heads/noid" out &&
	git update-ref -d refs/cs/heads/noid
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
