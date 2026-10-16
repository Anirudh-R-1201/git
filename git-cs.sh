#!/bin/sh
#
# git cs: version captured context in a history separate from code.
#
# A checkpoint is a commit whose tree holds a single typed message:
#
#	kind: <kind>
#	code: <commit>		optional: the code state it was captured against
#
#	<body>
#
# Code commits name the checkpoint they were made from in their "context"
# header (git commit --context), so every code commit leads to one point of
# the context history, while a checkpoint may name at most one code commit.

SUBDIRECTORY_OK=Yes
USAGE='init
   or: commit <branch> (-m <message> | -F <file>) [--kind <kind>] [--code <commit>] [--expect <checkpoint>]
   or: show <checkpoint>
   or: context <checkpoint>
   or: log <checkpoint>
   or: diff <checkpoint> <checkpoint>
   or: branch <name> <checkpoint>
   or: switch [-c] <workspace> <branch> [<checkpoint>]
   or: reset <branch> <checkpoint>
   or: reflog <branch>
   or: tag <name> <checkpoint>
   or: label (add | remove) <name> <checkpoint>...
   or: label resolve <name>
   or: merge <branch> <checkpoint> [-m <message>] [--no-ff] [--retry <n>]
   or: rebase <branch> <onto>
   or: cherry-pick <branch> <checkpoint>
   or: revert <branch> <checkpoint>
   or: pin <checkpoint>...
   or: unpin <checkpoint>...
   or: commit-code --context <checkpoint> -- <git-commit-options>
   or: fsck [<code-revs>...]
   or: links (--code <commit> | --context <checkpoint> [<code-refs>...])
   or: push <remote> [<code-refspec>...]
   or: fetch <remote>
   or: bundle <file> [<code-refs>...]'

. git-sh-setup

tmp="$GIT_DIR/cs-tmp.$$"
trap 'rm -f "$tmp".*' 0

# A conditional update lost a race; callers may retry on this exit status.
stale () {
	echo >&2 "STALE_TIP"
	exit 75
}

# A branch name, or @<workspace> for the branch that workspace selected.
ref () {
	case "$1" in
	@*) git symbolic-ref refs/cs/workspaces/"${1#@}" ;;
	*) echo "refs/cs/heads/$1" ;;
	esac
}

# Print the full ID of checkpoint $1, or die. Context branch names win over code refs.
rev () {
	c=$(git rev-parse -q --verify "$(ref "$1" 2>/dev/null)^{commit}" || git rev-parse -q --verify "$1^{commit}") &&
	test "$(git ls-tree --name-only $c 2>/dev/null)" = message && echo $c ||
	die "not a cs checkpoint: $1"
}

# Write the typed message: kind, optional code commit, optional retracted checkpoint, body.
write_message () {
	case "$1" in
	""|*[!a-z0-9-]*) die "invalid kind: $1" ;;
	esac
	test -n "$4" || die "empty message"
	{
		echo "kind: $1"
		test -z "$2" || echo "code: $2"
		test -z "$3" || echo "retracts: $3"
		echo
		printf '%s\n' "$4"
	} >"$tmp.msg"
}

# Store $tmp.msg as a checkpoint with the given parents and print its ID.
checkpoint () {
	parents=
	for p
	do
		parents="$parents -p $p"
	done
	subject=$(sed -n '/^$/{n;p;q;}' "$tmp.msg")
	tree=$(printf '100644 blob %s\tmessage\n' "$(git hash-object -w "$tmp.msg")" | git mktree) &&
	git commit-tree $tree $parents -m "$(sed -n '1s/^kind: //p' "$tmp.msg"): $subject"
}

body () {
	git cat-file blob "$1:message" | sed '1,/^$/d'
}

cmd_init () {
	git config commit.requireContext true
}

cmd_commit () {
	branch=$1 message= kind=message code= expect=
	shift
	while test $# -gt 0
	do
		case "$1" in
		-m) message=$2; shift ;;
		-F) message=$(cat "$2") || exit; shift ;;
		--kind) kind=$2; shift ;;
		--code) code=$2; shift ;;
		--expect) expect=$2; shift ;;
		*) usage ;;
		esac
		shift
	done
	git check-ref-format "$(ref "$branch" 2>/dev/null)" || die "invalid context branch: $branch"
	if test -n "$code"
	then
		code=$(git rev-parse -q --verify "$code^{commit}") || die "not a commit: $code"
	fi
	tip=$(git rev-parse -q --verify "$(ref "$branch")")
	write_message "$kind" "$code" "" "$message"
	commit=$(checkpoint $tip) || exit
	git update-ref --create-reflog "$(ref "$branch")" $commit "${expect:-$tip}" 2>/dev/null || stale
	echo $commit
}

cmd_show () {
	c=$(rev "$1") || exit
	git cat-file blob $c:message
}

# Every message leading to the checkpoint, oldest first, without merges and retracted ones.
cmd_context () {
	c=$(rev "$1") || exit
	retracted=$(git rev-list $c | while read -r r
		do
			git cat-file blob $r:message | sed -n '/^$/q; s/^retracts: //p'
		done | tr '\n' ' ')
	git rev-list --reverse --topo-order $c |
	while read -r r
	do
		kind=$(git cat-file blob $r:message | sed -n '1s/^kind: //p')
		case "$kind" in
		merge|retract) continue ;;
		esac
		case " $retracted " in
		*" $r "*) continue ;;
		esac
		printf '%s %s: %s\n' $(git rev-parse --short $r) "$kind" "$(body $r)"
	done
}

cmd_log () {
	c=$(rev "$1") || exit
	git log --date=short --format='%h %ad %s' $c
}

cmd_diff () {
	a=$(rev "$1") && b=$(rev "$2") || exit
	git log --format='- %h %s' $b..$a
	git log --format='+ %h %s' $a..$b
}

cmd_branch () {
	start=$(rev "$2") || exit
	git update-ref --create-reflog "$(ref "$1")" $start ""
}

cmd_switch () {
	test "$1" != -c || { shift; cmd_branch "$2" "$3" || exit; }
	git rev-parse -q --verify "$(ref "$2")" >/dev/null || die "no such branch: $2"
	git symbolic-ref refs/cs/workspaces/"$1" "$(ref "$2")"
}

cmd_reset () {
	old=$(git rev-parse --verify "$(ref "$1")") &&
	new=$(rev "$2") || exit
	git update-ref --create-reflog refs/cs/recovery/"$1" $old &&
	git update-ref --create-reflog "$(ref "$1")" $new $old
}

cmd_reflog () {
	git reflog show "$(ref "$1")"
}

cmd_tag () {
	c=$(rev "$2") &&
	git update-ref refs/cs/tags/"$1" $c ""
}

cmd_label () {
	op=$1 name=$2
	shift 2
	for c in "$@"
	do
		c=$(rev "$c") || exit
		case "$op" in
		add) git update-ref refs/cs/labels/$name/$c $c ;;
		remove) git update-ref -d refs/cs/labels/$name/$c ;;
		*) usage ;;
		esac || exit
	done
	test "$op" != resolve || git for-each-ref --format='%(objectname)' refs/cs/labels/$name/
}

# Print a copy of checkpoint $2 on top of $1; a message never conflicts.
replay () {
	git log -1 --format=%B $2 | git commit-tree $2^{tree} -p $1
}

cmd_rebase () {
	old=$(git rev-parse --verify "$(ref "$1")") &&
	new=$(rev "$2") || exit
	test -z "$(git rev-list --min-parents=2 $new..$old)" || die "cannot replay merge checkpoints"
	for c in $(git rev-list --reverse $new..$old)
	do
		new=$(replay $new $c) || exit
	done
	git update-ref --create-reflog refs/cs/recovery/"$1" $old &&
	git update-ref --create-reflog "$(ref "$1")" $new $old 2>/dev/null || stale
	echo $new
}

cmd_cherry_pick () {
	old=$(git rev-parse --verify "$(ref "$1")") &&
	c=$(rev "$2") &&
	new=$(replay $old $c) || exit
	git update-ref --create-reflog "$(ref "$1")" $new $old 2>/dev/null || stale
	echo $new
}

cmd_revert () {
	old=$(git rev-parse --verify "$(ref "$1")") &&
	c=$(rev "$2") || exit
	write_message retract "" $c "Retract: $(git log -1 --format=%s $c)"
	new=$(checkpoint $old) || exit
	git update-ref --create-reflog "$(ref "$1")" $new $old 2>/dev/null || stale
	echo $new
}

cmd_merge () {
	branch=$1 name=$2 message= noff= retry=0
	shift 2
	while test $# -gt 0
	do
		case "$1" in
		-m) message=$2; shift ;;
		--no-ff) noff=1 ;;
		--retry) retry=$2; shift ;;
		*) usage ;;
		esac
		shift
	done
	n=0
	while :
	do
		(merge_once)
		status=$?
		test $status = 75 && test $n -lt $retry || return $status
		n=$((n + 1))
		# Exponential backoff with per-process jitter, capped at about six seconds.
		sleep $(awk -v n=$n -v seed=$$ 'BEGIN { srand(seed * 64 + n); printf "%.2f", rand() * 0.1 * 2 ^ (n < 6 ? n : 6) }')
	done
}

merge_once () {
	ours=$(git rev-parse --verify "$(ref "$branch")") &&
	theirs=$(rev "$name") || exit
	git merge-base --is-ancestor $theirs $ours && {
		echo >&2 "Already up to date"
		echo $ours
		return
	}
	git merge-base --is-ancestor $ours $theirs && test -z "$noff" && {
		git update-ref --create-reflog "$(ref "$branch")" $theirs $ours 2>/dev/null || stale
		echo >&2 "Fast-forward"
		echo $theirs
		return
	}
	write_message merge "" "" "${message:-Merge $name}"
	new=$(checkpoint $ours $theirs) || exit
	git update-ref --create-reflog "$(ref "$branch")" $new $ours 2>/dev/null || stale
	echo >&2 "Merge checkpoint"
	echo $new
}

cmd_pin () {
	for c in "$@"
	do
		c=$(rev "$c") &&
		git update-ref refs/cs/pins/$c $c || exit
	done
}

cmd_unpin () {
	for c in "$@"
	do
		c=$(rev "$c") &&
		git update-ref -d refs/cs/pins/$c || exit
	done
}

cmd_commit_code () {
	ctx=$(rev "$2") || exit
	shift 2
	test "$1" = -- && shift
	cmd_pin $ctx &&
	git commit --context $ctx "$@"
}

# Code commits with the number of context headers they carry and the last one.
code_links () {
	git log --pretty=raw "$@" |
	awk '/^commit / { if (c) print c, n, v; c = $2; n = 0; v = "" }
		/^context / { n++; v = $2 }
		END { if (c) print c, n, v }'
}

cmd_fsck () {
	bad=$(git for-each-ref --format='%(objectname) %(refname)' refs/cs/ |
	while read -r c name
	do
		if test "$(git ls-tree --name-only $c 2>/dev/null)" != message
		then
			echo "not a checkpoint: $name"
			continue
		fi
		code=$(git cat-file blob $c:message | sed -n '/^$/q; s/^code: //p')
		test -z "$code" || git cat-file -e "$code^{commit}" 2>/dev/null ||
		echo "missing code commit: $name -> $code"
	done
	code_links "${@:---branches}" |
	while read -r code n ctx
	do
		case "$n" in
		(0) echo "unlinked: $code" ;;
		(1) git rev-parse -q --verify refs/cs/pins/$ctx >/dev/null || echo "unpinned link: $code -> $ctx" ;;
		(*) echo "several links: $code" ;;
		esac
	done)
	test -z "$bad" || die "$bad"
}

cmd_links () {
	case "$1" in
	--code)
		git cat-file commit "${2:-HEAD}" | sed -n '/^$/q; s/^context //p' ;;
	--context)
		ctx=$(rev "$2") || exit
		shift 2
		code_links "${@:---branches}" | awk -v ctx=$ctx '$2 == 1 && $3 == ctx { print $1 }' ;;
	*)
		usage ;;
	esac
}

cmd_push () {
	remote=$1
	shift
	git push --atomic "$remote" "refs/cs/heads/*:refs/cs/heads/*" "refs/cs/pins/*:refs/cs/pins/*" "refs/cs/tags/*:refs/cs/tags/*" "refs/cs/labels/*:refs/cs/labels/*" "$@"
}

cmd_fetch () {
	git fetch "$1" "refs/cs/heads/*:refs/cs/remotes/$1/*" "refs/cs/pins/*:refs/cs/pins/*" "refs/cs/tags/*:refs/cs/tags/*" "refs/cs/labels/*:refs/cs/labels/*"
}

cmd_bundle () {
	file=$1
	shift
	{
		git for-each-ref --format='%(refname)' refs/cs/heads refs/cs/pins refs/cs/tags refs/cs/labels
		printf '%s\n' "$@"
	} | git bundle create "$file" --stdin
}

cmd=$1
shift
case "$cmd" in
init|commit|show|context|log|diff|branch|switch|reset|reflog|tag|label|merge|rebase|\
cherry-pick|revert|pin|unpin|commit-code|fsck|links|push|fetch|bundle)
	cmd_$(echo "$cmd" | tr - _) "$@" ;;
*)
	usage ;;
esac
