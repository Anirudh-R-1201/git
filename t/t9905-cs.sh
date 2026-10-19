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
	printf "kind: message\nfrom: A-U-Thor\n\nInvestigate SQLite\n" >expect &&
	test_cmp expect actual
'

test_expect_success 'commit takes a kind, an optional code commit and a message file' '
	printf "Use WAL mode\n\nback\\\\slash and \\\\n stay literal\n" >msg &&
	two=$(git cs commit main -F msg --kind learning --code HEAD) &&
	show_without_id $two >actual &&
	{
		echo "kind: learning" &&
		echo "from: A-U-Thor" &&
		echo "code: $(git rev-parse HEAD)" &&
		echo &&
		cat msg
	} >expect &&
	test_cmp expect actual &&
	git log -1 --format=%s $two >subject &&
	echo "learning: Use WAL mode" >expect &&
	test_cmp expect subject
'

test_expect_success 'commit -F keeps trailing blank lines' '
	printf "body\n\n\n" >msg &&
	c=$(git cs commit file-body -F msg) &&
	git cs show $c | sed "1,/^\$/d" >actual &&
	test_cmp msg actual &&
	printf "no final newline" >msg &&
	c=$(git cs commit file-body -F msg) &&
	git cs show $c | sed "1,/^\$/d" >actual &&
	test_cmp msg actual
'

test_expect_success 'a body without a final newline does not hide later notes' '
	git cs branch no-newline $base &&
	git cs branch no-newline-me $base &&
	git cs branch no-newline-copy $base &&
	printf "line one\nline two" >msg &&
	first=$(git cs commit no-newline -F msg --kind decision --from x) &&
	second=$(git cs commit no-newline -m after --kind decision --from x) &&
	git cs commit no-newline -m third --kind decision --from x &&
	git cs context no-newline | sed "s/^[0-9a-f]* //" >actual &&
	printf "x decision: line one\nline two\nx decision: after\nx decision: third\n" >expect &&
	tail -n 4 actual >tail &&
	test_cmp expect tail &&
	git cs sync no-newline-me no-newline | cut -d " " -f 2- >actual &&
	test_grep "^x decision: after\$" actual &&
	test_grep "^x decision: third\$" actual &&
	git cs cherry-pick no-newline-copy $first &&
	git cs cherry-pick no-newline-copy $second &&
	copy=$(git rev-parse refs/cs/heads/no-newline-copy) &&
	git cs rebase no-newline no-newline-copy &&
	test "$(git rev-list --count $copy..refs/cs/heads/no-newline)" = 1
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

test_expect_success 'commit --expect accepts a context branch name' '
	git cs branch exp main &&
	git cs commit exp -m by-name --expect exp &&
	test_expect_code 75 git cs commit exp -m stale --expect main
'

test_expect_success 'messages record who sent them' '
	git cs branch who main &&
	git cs commit who -m one --from alpha &&
	GIT_CS_FROM=beta git cs commit who -m two &&
	test_config cs.from gamma &&
	git cs commit who -m three &&
	test_must_fail git cs commit who -m bad --from "has space" &&
	git cs context who | tail -n 3 | cut -d " " -f 2 >actual &&
	printf "alpha\nbeta\ngamma\n" >expect &&
	test_cmp expect actual &&
	git cs log who | head -n 1 >top &&
	test_grep " gamma message: three$" top
'

test_expect_success 'context lists every message oldest first' '
	git cs context main | sed "s/^[0-9a-f]* [^ ]* //" >actual &&
	cat >expect <<-\EOF &&
	message: Investigate SQLite
	learning: Use WAL mode

	back\slash and \n stay literal
	message: three
	EOF
	test_cmp expect actual
'

test_expect_success 'context narrows by --since, --last, --kind and --from' '
	git cs context who --since main | cut -d " " -f 2- >actual &&
	printf "alpha message: one\nbeta message: two\ngamma message: three\n" >expect &&
	test_cmp expect actual &&
	git cs context who --last 2 | cut -d " " -f 2- >actual &&
	printf "beta message: two\ngamma message: three\n" >expect &&
	test_cmp expect actual &&
	git cs context who --from alpha,gamma | cut -d " " -f 2- >actual &&
	printf "alpha message: one\ngamma message: three\n" >expect &&
	test_cmp expect actual &&
	git cs context who --kind learning | head -n 1 | cut -d " " -f 3- >actual &&
	echo "learning: Use WAL mode" >expect &&
	test_cmp expect actual
'

test_expect_success 'context includes older messages without a from field' '
	git cs commit legacy-source -m "older learning" --kind learning &&
	git cs show legacy-source | sed "/^from: /d" >legacy-message &&
	legacy_tree=$(printf "100644 blob %s\tmessage\n" "$(git hash-object -w legacy-message)" | git mktree) &&
	legacy=$(git commit-tree "$legacy_tree" -p "$base" -m "learning: older learning") &&
	git cs branch legacy "$legacy" &&
	git cs context legacy >actual &&
	test_grep "learning: older learning" actual
'

test_expect_success 'context --since respects earlier retractions' '
	git cs branch since-retract $base &&
	old=$(git cs commit since-retract -m old) &&
	git cs revert since-retract $old &&
	cut=$(git rev-parse refs/cs/heads/since-retract) &&
	git cs cherry-pick since-retract $old &&
	git cs context since-retract --since $cut >actual &&
	test_must_be_empty actual
'

test_expect_success 'context --since does not repeat an earlier message' '
	git cs branch since-copy $base &&
	old=$(git cs commit since-copy -m once) &&
	cut=$(git rev-parse refs/cs/heads/since-copy) &&
	git cs cherry-pick since-copy $old &&
	git cs context since-copy --since $cut >actual &&
	test_must_be_empty actual
'

test_expect_success 'a superseding message replaces the old one in context' '
	git cs branch claims $base &&
	git cs branch rival $base &&
	path=$(git cs commit claims -m "store a path") &&
	git cs commit rival -m "store a URI" &&
	git cs merge claims rival &&
	git cs commit claims -m "store a URI; paths break on Windows" --kind decision --supersedes $path &&
	git cs show claims >msg &&
	test_grep "^supersedes: $(git cs show $path | sed -n "s/^id: //p")$" msg &&
	git cs context claims | cut -d " " -f 3- >actual &&
	cat >expect <<-\EOF &&
	message: Investigate SQLite
	message: store a URI
	decision: store a URI; paths break on Windows
	EOF
	test_cmp expect actual
'

test_expect_success 'context --path keeps notes about that path and general notes' '
	git cs branch scoped $base &&
	git cs commit scoped -m "parser rule" --path src/parse.py --path src/lex.py &&
	git cs commit scoped -m "docs style" --path docs &&
	git cs show scoped~1 >msg &&
	test_grep "^path: src/lex.py$" msg &&
	git cs context scoped --path src/parse.py | cut -d " " -f 3- >actual &&
	printf "message: Investigate SQLite\nmessage: parser rule\n" >expect &&
	test_cmp expect actual &&
	git cs context scoped --path src/ | cut -d " " -f 3- >actual &&
	test_cmp expect actual &&
	git cs context scoped --path docs/style.md | cut -d " " -f 3- >actual &&
	printf "message: Investigate SQLite\nmessage: docs style\n" >expect &&
	test_cmp expect actual
'

test_expect_success 'sync shows only new messages from others and remembers them' '
	git cs branch team $base &&
	git cs branch mine $base &&
	git cs commit team -m "from x" --from x &&
	git cs commit mine -m "my own" &&
	git cs sync mine team | cut -d " " -f 2- >actual &&
	echo "x message: from x" >expect &&
	test_cmp expect actual &&
	git cs sync mine team >actual &&
	test_must_be_empty actual &&
	git cs commit team -m "later from y" --from y &&
	git cs sync mine team | cut -d " " -f 2- >actual &&
	echo "y message: later from y" >expect &&
	test_cmp expect actual &&
	git reflog show refs/cs/seen/mine >log &&
	test_line_count = 2 log
'

test_expect_success 'filtered sync leaves other messages unread' '
	git cs branch filtered-team $base &&
	git cs branch filtered-me $base &&
	git cs commit filtered-team -m backend --from x --path src/backend &&
	git cs commit filtered-team -m frontend --from y --path src/frontend &&
	git cs sync filtered-me filtered-team --path src/backend >actual &&
	test_grep "message: backend" actual &&
	test_grep ! "message: frontend" actual &&
	test_must_fail git rev-parse -q --verify refs/cs/seen/filtered-me &&
	git cs sync filtered-me filtered-team >actual &&
	test_grep "message: frontend" actual
'

test_expect_success 'sync reports a newly retracted note' '
	git cs branch retraction-team $base &&
	git cs branch retraction-me $base &&
	note=$(git cs commit retraction-team -m obsolete --from x) &&
	git cs sync retraction-me retraction-team >actual &&
	test_grep "message: obsolete" actual &&
	GIT_CS_FROM=x git cs revert retraction-team $note &&
	git cs sync retraction-me retraction-team >actual &&
	test_grep "x retract: Retract: message: obsolete" actual &&
	git cs context retraction-me >actual &&
	test_grep ! "obsolete" actual
'

# Publish a learning from z a few seconds from now.
deliver_late () {
	(sleep 3 && git cs commit lateteam -m arrived --from z --kind learning >/dev/null) &
}

test_expect_success 'wait returns once the awaited senders have published' '
	git cs branch lateteam $base &&
	git cs branch waiter $base &&
	deliver_late &&
	git cs wait waiter lateteam --from z --kind learning --timeout 60 >out 2>err &&
	wait &&
	test_grep "z learning: arrived" out &&
	test_grep "waiting for: z" err &&
	test_must_fail git cs wait waiter lateteam --from nobody --timeout 1 2>err &&
	test_grep "timed out waiting for: nobody" err
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
	git cs context a | sed "s/^[0-9a-f]* [^ ]* //" | sort >actual &&
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
	git cs context shared | sed "s/^[0-9a-f]* [^ ]* message: //" | grep "^p" | sort >actual &&
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
	git cs context topic | sed "s/^[0-9a-f]* [^ ]* message: //" >actual &&
	printf "Investigate SQLite\nfrom b\nt1\nt2\n" >expect &&
	test_cmp expect actual &&
	test_must_fail git cs rebase a topic 2>err &&
	test_grep "cannot replay merge checkpoints" err
'

test_expect_success 'rebase keeps retractions of replayed messages' '
	git cs branch retract-topic $base &&
	learning=$(git cs commit retract-topic -m "obsolete learning" --kind learning) &&
	git cs revert retract-topic "$learning" &&
	git cs rebase retract-topic b &&
	git cs context retract-topic >actual &&
	test_grep "from b" actual &&
	test_grep ! "obsolete learning" actual
'

test_expect_success 'rebase skips message IDs already on its destination' '
	git cs branch dedup-source "$base" &&
	first=$(git cs commit dedup-source -m "shared discovery" --kind learning) &&
	git cs commit dedup-source -m "new contract" --kind decision &&
	git cs branch dedup-target "$base" &&
	git cs cherry-pick dedup-target "$first" &&
	git cs commit dedup-target -m "target note" &&
	target=$(git rev-parse refs/cs/heads/dedup-target) &&
	git cs rebase dedup-source dedup-target &&
	test "$(git rev-list --count "$target"..refs/cs/heads/dedup-source)" = 1 &&
	git cs context dedup-source >actual &&
	test "$(grep -c "shared discovery" actual)" = 1 &&
	test_grep "decision: new contract" actual
'

test_expect_success 'copies keep the author, and the committer records the copy' '
	git cs branch author-src $base &&
	original=$(GIT_AUTHOR_NAME=Alice GIT_AUTHOR_EMAIL=alice@example.com \
		GIT_AUTHOR_DATE="1700000000 +0000" \
		git cs commit author-src -m "alice learning" --kind learning) &&
	git cs branch author-pick $base &&
	git cs commit author-pick -m "pick base" &&
	test_tick &&
	copy=$(git cs cherry-pick author-pick $original) &&
	git cs rebase author-src author-pick &&
	rebased=$(git rev-parse refs/cs/heads/author-src) &&
	git log -1 --format="%an <%ae> %ad" $original >expect &&
	git log -1 --format="%an <%ae> %ad" $copy >actual &&
	test_cmp expect actual &&
	git log -1 --format="%an <%ae> %ad" $rebased >actual &&
	test_cmp expect actual &&
	git log -1 --format="%cn %cd" $copy >committer &&
	test_grep "^$GIT_COMMITTER_NAME " committer &&
	test "$(git log -1 --format=%ct $copy)" != 1700000000
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
	test_grep ! "picked learning" actual
'

test_expect_success 'a merged retraction hides a copy picked earlier' '
	git cs branch id-merge $base &&
	git cs cherry-pick id-merge "$learning" &&
	git cs merge id-merge id-src --no-ff &&
	git cs context id-merge >actual &&
	test_grep ! "picked learning" actual
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

test_expect_success 'rebase onto included or newer context does not rewrite' '
	tip=$(git rev-parse refs/cs/heads/topic) &&
	git cs rebase topic b 2>err &&
	echo "Already up to date" >expect &&
	test_cmp expect err &&
	test "$(git rev-parse refs/cs/heads/topic)" = $tip &&
	git cs branch behind $base &&
	git cs rebase behind b 2>err &&
	echo Fast-forward >expect &&
	test_cmp expect err &&
	test "$(git rev-parse refs/cs/heads/behind)" = "$(git rev-parse refs/cs/heads/b)"
'

test_expect_success 'cherry-pick copies one message and revert retracts it' '
	git cs branch pick $base &&
	git cs cherry-pick pick topic &&
	git cs context pick | sed "s/^[0-9a-f]* [^ ]* message: //" >actual &&
	printf "Investigate SQLite\nt2\n" >expect &&
	test_cmp expect actual &&
	git cs revert pick pick &&
	test "$(kind_of pick)" = retract &&
	git cs context pick | sed "s/^[0-9a-f]* [^ ]* message: //" >actual &&
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

test_expect_success 'a plain git commit --context pins its checkpoint after init' '
	git cs branch native $base &&
	ctx=$(git cs commit native -m "native link") &&
	git commit --allow-empty --context $ctx -m native &&
	git rev-parse refs/cs/pins/$ctx &&
	git cs fsck HEAD^..HEAD
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
	git update-ref -d refs/cs/heads/noid &&
	bad=$(git commit-tree -p refs/cs/heads/main -m noid $tree) &&
	git cs branch noid-ancestor $bad &&
	git cs commit noid-ancestor -m "valid tip" &&
	test_must_fail git cs fsck code..HEAD >out 2>&1 &&
	test_grep "missing id: $bad" out &&
	git update-ref -d refs/cs/heads/noid-ancestor
'

test_expect_success 'fsck checks the code link of every reachable checkpoint' '
	git cs branch deep main &&
	git cs commit deep -m "points at code" --code HEAD &&
	git cs commit deep -m "newer tip" &&
	git cs fsck code..HEAD &&
	git cat-file -p refs/cs/heads/deep~1:message |
		sed "s/^code: .*/code: $(test_oid deadbeef)/" >msg &&
	tree=$(printf "100644 blob %s\tmessage\n" $(git hash-object -w msg) | git mktree) &&
	bad=$(git commit-tree $tree -p refs/cs/heads/deep~2 -m broken) &&
	git cs branch broken $bad &&
	git cs commit broken -m "tip is fine" &&
	test_must_fail git cs fsck code..HEAD >out 2>&1 &&
	test_grep "missing code commit: $bad" out &&
	git update-ref -d refs/cs/heads/broken
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

test_expect_success 'selective fetch recovers a rewritten tracking branch explicitly' '
	git init --bare fetch-hub.git &&
	git cs branch fetch-a "$base" &&
	a=$(git cs commit fetch-a -m "first a") &&
	git cs branch fetch-b "$base" &&
	git cs commit fetch-b -m "first b" &&
	git push fetch-hub.git refs/cs/heads/fetch-a refs/cs/heads/fetch-b &&
	git init fetch-rx &&
	git -C fetch-rx remote add origin ../fetch-hub.git &&
	git -C fetch-rx cs fetch origin --context fetch-a &&
	test "$(git -C fetch-rx rev-parse refs/cs/remotes/origin/fetch-a)" = "$a" &&
	test_must_fail git -C fetch-rx rev-parse -q --verify refs/cs/remotes/origin/fetch-b &&
	git push -f fetch-hub.git "$base":refs/cs/heads/fetch-a &&
	test_must_fail git -C fetch-rx cs fetch origin --context fetch-a &&
	git -C fetch-rx cs fetch origin --context fetch-a --force &&
	test "$(git -C fetch-rx rev-parse refs/cs/remotes/origin/fetch-a)" = "$base" &&
	test "$(git -C fetch-rx rev-parse refs/cs/fetch-recovery/origin/fetch-a)" = "$a"
'

test_expect_success 'forced fetch recovery does not collide with a context branch named fetch' '
	git -C fetch-rx cs commit fetch -m one &&
	git -C fetch-rx cs commit fetch -m two &&
	git -C fetch-rx cs reset fetch refs/cs/heads/fetch~1 &&
	git push -f fetch-hub.git "$a":refs/cs/heads/fetch-a &&
	git -C fetch-rx cs fetch origin --context fetch-a &&
	git push -f fetch-hub.git "$base":refs/cs/heads/fetch-a &&
	git -C fetch-rx cs fetch origin --context fetch-a --force &&
	test "$(git -C fetch-rx rev-parse refs/cs/fetch-recovery/origin/fetch-a)" = "$a" &&
	git -C fetch-rx rev-parse refs/cs/recovery/fetch
'

test_expect_success 'remote lets plain fetch and pull bring context' '
	git clone hub.git rx2 &&
	test_must_fail git -C rx2 rev-parse -q --verify refs/cs/remotes/origin/a &&
	git -C rx2 cs remote origin &&
	git -C rx2 cs remote origin &&
	git -C rx2 config --get-all remote.origin.fetch >specs &&
	test_line_count = 5 specs &&
	git -C rx2 pull &&
	git -C rx2 rev-parse refs/cs/remotes/origin/a refs/cs/tags/v1 &&
	git -C rx2 cs show "$(git -C rx2 cs links --code HEAD)"
'

test_expect_success 'init sets up every configured remote' '
	git clone hub.git rx3 &&
	git -C rx3 cs init &&
	git -C rx3 fetch &&
	git -C rx3 rev-parse refs/cs/remotes/origin/a
'

test_expect_success 'push is atomic across code and context' '
	git push -f hub.git "$(git commit-tree HEAD^{tree} -m other)":refs/heads/master &&
	before=$(git -C hub.git rev-parse refs/cs/heads/a) &&
	git cs commit a -m newer &&
	test_must_fail git cs push hub.git HEAD:refs/heads/master &&
	test "$(git -C hub.git rev-parse refs/cs/heads/a)" = $before
'

test_expect_success 'push --context publishes only chosen branches and needed pins' '
	git init --bare hub2.git &&
	lonely=$(git cs commit lonely -m unrelated) &&
	git push hub2.git $lonely:refs/cs/heads/b &&
	test_must_fail git cs push hub2.git HEAD:refs/heads/master &&
	git cs push hub2.git --context a HEAD:refs/heads/master &&
	git -C hub2.git rev-parse refs/cs/heads/a &&
	test_must_fail git -C hub2.git rev-parse -q --verify refs/cs/heads/main &&
	test "$(git -C hub2.git rev-parse refs/cs/heads/b)" = $lonely &&
	git -C hub2.git rev-parse refs/cs/pins/$(git cs links --code HEAD)
'

test_expect_success 'scoped push sends pins when code is already on the remote' '
	git init --bare hub3.git &&
	git remote add hub3 hub3.git &&
	git push hub3 HEAD:refs/heads/main &&
	git fetch hub3 main &&
	ctx=$(git cs links --code HEAD) &&
	git cs push hub3 --context native HEAD:refs/heads/main &&
	git -C hub3.git rev-parse refs/cs/pins/$ctx
'

test_expect_success 'bundle carries context offline' '
	git cs bundle cs.bundle HEAD &&
	git init offline &&
	git -C offline fetch ../cs.bundle "refs/cs/*:refs/cs/*" HEAD:refs/heads/in &&
	git -C offline cs show "$(git -C offline cs links --code in)"
'

test_expect_success 'commit --expect none refuses a branch someone else created' '
	first=$(git cs commit expect-new -m first --expect none) &&
	test_expect_code 75 git cs commit expect-new -m second --expect none 2>err &&
	test_grep "^STALE_TIP\$" err &&
	test "$(git rev-parse refs/cs/heads/expect-new)" = "$first"
'

test_expect_success 'a new branch forks from cs.base unless --root is given' '
	test_config cs.base main &&
	based=$(git cs commit based -m "forked note") &&
	test "$(git rev-parse $based^)" = "$(git rev-parse refs/cs/heads/main)" &&
	rooted=$(git cs commit rooted -m "fresh tree" --root) &&
	test_must_fail git rev-parse -q --verify $rooted^
'

test_expect_success 'commit --no-update prepares chained checkpoints for one transaction' '
	tip=$(git rev-parse refs/cs/heads/main) &&
	one=$(git cs commit main -m prepared-one --no-update) &&
	two=$(git cs commit main -m prepared-two --no-update --onto $one) &&
	test "$(git rev-parse refs/cs/heads/main)" = "$tip" &&
	test "$(git rev-parse $two^)" = "$one" &&
	test "$(git rev-parse $one^)" = "$tip" &&
	printf "start\nupdate refs/cs/heads/main %s %s\nprepare\ncommit\n" $two $tip |
		git update-ref --stdin &&
	git cs context main --last 2 >actual &&
	test_grep "message: prepared-one" actual &&
	test_grep "message: prepared-two" actual &&
	test_must_fail git cs commit main -m stray --onto $one 2>err &&
	test_grep "requires --no-update" err
'

test_expect_success 'cherry-pick and revert --no-update leave the branch alone' '
	git cs branch staged $base &&
	tip=$(git rev-parse refs/cs/heads/staged) &&
	picked=$(git cs cherry-pick staged topic --no-update) &&
	retracted=$(git cs revert staged $picked --no-update --onto $picked) &&
	test "$(git rev-parse refs/cs/heads/staged)" = "$tip" &&
	test "$(git rev-parse $retracted^)" = "$picked" &&
	test "$(git rev-parse $picked^)" = "$tip"
'

test_expect_success 'pin and unpin change all named pins or none' '
	git cs branch pin-a $base &&
	a=$(git cs commit pin-a -m pinned-a) &&
	test_must_fail git cs pin $a nope &&
	test_must_fail git rev-parse -q --verify refs/cs/pins/$a &&
	git cs pin $a &&
	test_must_fail git cs unpin $a nope &&
	git rev-parse -q --verify refs/cs/pins/$a &&
	git cs unpin $a &&
	test_must_fail git rev-parse -q --verify refs/cs/pins/$a
'

test_expect_success 'acks record which notes a recipient used' '
	git cs branch ack-team $base &&
	contract=$(git cs commit ack-team -m contract --from api) &&
	git cs commit ack-team -m "other note" --from api &&
	git cs commit ack-team -m "used the contract" --from client --acks $contract &&
	git cs show refs/cs/heads/ack-team | sed -n "s/^acks: //p" >actual &&
	git cs show $contract | sed -n "s/^id: //p" >expect &&
	test_cmp expect actual &&
	git cs context ack-team --acked-by client >actual &&
	test_grep "api message: contract" actual &&
	test_line_count = 1 actual &&
	git cs context ack-team --acked-by nobody >actual &&
	test_must_be_empty actual &&
	git cs context ack-team --unacked --from api >actual &&
	test_grep "api message: other note" actual &&
	test_line_count = 1 actual &&
	test_must_fail git cs context ack-team --acked-by client --unacked
'

test_expect_success 'context --format brief and --max-bytes bound what is printed' '
	git cs branch bounded $base &&
	printf "first line\nmore detail\n" >msg &&
	git cs commit bounded -F msg &&
	git cs commit bounded -m newest &&
	git cs context bounded --format brief >actual &&
	test_grep "message: first line\$" actual &&
	test_grep ! "more detail" actual &&
	git cs context bounded | tail -1 >newest &&
	git cs context bounded --max-bytes $(wc -c <newest) >actual &&
	test_cmp newest actual &&
	git cs context bounded --max-bytes 1 >actual &&
	test_must_be_empty actual &&
	test_must_fail git cs context bounded --max-bytes many
'

test_expect_success 'integrate merges context branches and links the code merge to them' '
	git init integrate &&
	(
		cd integrate &&
		test_commit start &&
		git cs commit team -m "team plan" &&
		git cs branch ctx-a team &&
		git cs branch ctx-b team &&
		git cs commit ctx-a -m "a contract" --from a &&
		git cs commit ctx-b -m "b contract" --from b &&
		git checkout -b side &&
		test_commit side-change &&
		git checkout - &&
		test_commit main-change &&
		git cs integrate team ctx-a ctx-b -- --no-edit side &&
		git rev-parse HEAD^2 &&
		ctx=$(git cs links --code HEAD) &&
		test "$ctx" = "$(git rev-parse refs/cs/heads/team)" &&
		git rev-parse -q --verify refs/cs/pins/$ctx &&
		git cs context team >actual &&
		test_grep "a message: a contract" actual &&
		test_grep "b message: b contract" actual
	)
'

test_expect_success 'heads lists each branch with its tip, message count and newest message' '
	git init heads &&
	(
		cd heads &&
		test_commit start &&
		git cs commit h1 -m one --from x &&
		tip=$(git cs commit h1 -m two --from x) &&
		git cs heads >actual &&
		echo "h1 $(git rev-parse --short=10 $tip) 2 x message: two" >expect &&
		test_cmp expect actual &&
		git cs commit h2 -m based --from y --root &&
		git config cs.base h1 &&
		git cs branch h3 h1 &&
		git cs commit h3 -m later --from z &&
		git cs heads >actual &&
		test_grep "^h3 [0-9a-f]* 1 z message: later\$" actual
	)
'

test_expect_success 'no temporary files are left behind' '
	test_path_is_missing .git/cs-tmp.*
'

test_done
