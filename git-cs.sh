#!/bin/sh
# Store context messages under refs/cs/; code commits link to checkpoints.

SUBDIRECTORY_OK=Yes
USAGE='init
   or: remote <name>
   or: commit <branch> (-m <message> | -F <file>) [--kind <kind>] [--code <commit>] [--from <name>] [--supersedes <checkpoint>] [--acks <checkpoint>]... [--path <path>]... [--expect (<checkpoint> | none)] [--root] [--no-update [--onto <checkpoint>]]
   or: show <checkpoint>
   or: context <checkpoint> [--since <checkpoint>] [--last <n>] [--kind <kinds>] [--from <names>] [--path <path>] [--acked-by <names> | --unacked] [--max-bytes <n>] [--format (full | brief)]
   or: heads
   or: sync <branch> <team> [<context-options>]
   or: wait <branch> <team> --from <names> [--kind <kinds>] [--timeout <seconds>]
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
   or: cherry-pick <branch> <checkpoint> [--no-update [--onto <checkpoint>]]
   or: revert <branch> <checkpoint> [--no-update [--onto <checkpoint>]]
   or: pin <checkpoint>...
   or: unpin <checkpoint>...
   or: commit-code --context <checkpoint> -- <git-commit-options>
   or: integrate <branch> <context-branch>... [-- <git-merge-options>]
   or: fsck [<code-revs>...]
   or: links (--code <commit> | --context <checkpoint> [<code-refs>...])
   or: push <remote> [--context <branch>]... [<code-refspec>...]
   or: fetch <remote> [--context <branch>]... [--force]
   or: bundle <file> [<code-refs>...]'

# git-sh-setup handles -h before trying to find a repository.
test "$1" != --help-all || set -- -h
. git-sh-setup

tmp="$GIT_DIR/cs-tmp.$$"
trap 'rm -f "$tmp".*' 0

from=${GIT_CS_FROM:-$(git config cs.from)}
from=${from:-$(git var GIT_AUTHOR_IDENT | sed 's/ <.*//; s/[^A-Za-z0-9._-]/-/g')}
code= retracts= supersedes= paths= acks= message_file=
f_kind= f_from= f_last= f_path= f_self= f_acked= f_unacked= f_bytes= f_brief=

# Apply the "git update-ref --stdin" commands on standard input in one
# transaction: either every ref changes or none does.
transaction () {
	{ echo start; cat; echo prepare; echo commit; } |
	git update-ref --stdin --create-reflog >/dev/null
}

# Parse --no-update and --onto <checkpoint>, which let a caller prepare a
# checkpoint without moving any ref and publish it later, for example with
# other refs in one transaction.
update_options () {
	no_update= onto=
	while test $# -gt 0
	do
		case "$1" in
		--no-update) no_update=1 ;;
		--onto) onto=$(rev "$2") || exit; shift ;;
		*) usage ;;
		esac
		shift
	done
	test -z "$onto" || test -n "$no_update" || die "--onto requires --no-update"
}

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

# Succeed if $1 is a commit whose tree holds only the regular file "message".
is_checkpoint () {
	git ls-tree "$1" 2>/dev/null |
	awk -F '\t' 'NR == 1 && $2 == "message" &&
		$1 ~ /^100(644|755) blob [0-9a-f]+$/ { valid = 1 }
		END { exit !(NR == 1 && valid) }'
}

# Print the full ID of checkpoint $1, or die. Context branch names win over code refs.
rev () {
	c=$(git rev-parse -q --verify "$(ref "$1" 2>/dev/null)^{commit}" || git rev-parse -q --verify "$1^{commit}") &&
		is_checkpoint "$c" && echo $c ||
	die "not a cs checkpoint: $1"
}

field () {
	git cat-file blob "$1:message" | sed -n "/^\$/q; s/^$2: //p"
}

new_id () {
	id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') &&
	test ${#id} = 32 && echo $id ||
	die "cannot generate a message id"
}

# Write a typed message of kind $1 with body $2, a new id, and the fields set in
# $from, $code, $retracts and $supersedes (message ids), and $acks and $paths (one per line).
write_message () {
	case "$1" in
	""|*[!a-z0-9-]*) die "invalid kind: $1" ;;
	esac
	case "$from" in
	""|*[!A-Za-z0-9._-]*) die "invalid sender: $from" ;;
	esac
	test -n "$2" || die "empty message"
	msg_id=$(new_id) || exit
	{
		echo "kind: $1"
		echo "id: $msg_id"
		echo "from: $from"
		test -z "$code" || echo "code: $code"
		test -z "$retracts" || echo "retracts: $retracts"
		test -z "$supersedes" || echo "supersedes: $supersedes"
		printf '%s' "$acks" | sed 's/^/acks: /'
		printf '%s' "$paths" | sed 's/^/path: /'
		echo
		if test -n "$message_file"
		then
			cat "$message_file"
		else
			printf '%s\n' "$2"
		fi
	} >"$tmp.msg"
}

checkpoint () {
	parents=
	for p
	do
		parents="$parents -p $p"
	done
	subject=$(sed -n '/^$/{n;p;q;}' "$tmp.msg")
	tree=$(printf '100644 blob %s\tmessage\n' "$(git hash-object -w "$tmp.msg")" | git mktree) &&
	GIT_AUTHOR_NAME=$from git commit-tree $tree $parents -m "$(sed -n '1s/^kind: //p' "$tmp.msg"): $subject"
}

# Read the messages of the given revisions in one pass and print them per mode:
# "context" prints visible messages oldest first, once per message id and without
# retracted ones, keeping only the last $f_last of those matching the comma lists
# $f_kind and $f_from and, unless they name no paths, concerning $f_path;
# "changes" also prints new retractions so a sync cannot silently hide old advice;
# $f_acked and $f_unacked keep messages acknowledged by one of the comma list
# $f_acked or by nobody, $f_bytes bounds the output to the newest messages that
# fit, and $f_brief prints only each message's first line;
# "codes" prints "<checkpoint> <code>".
read_messages () {
	mode=$1
	shift
	selected=
	if test "$mode" != codes && test $# -gt 1
	then
		git rev-list --reverse --topo-order "$@" >"$tmp.selected" || return
		selected=$tmp.selected
		set -- "$1"
	fi
	git rev-list --reverse --topo-order "$@" |
	sed 's/.*/&:message &/' |
	git cat-file --batch='%(objectsize) %(rest)' |
	LC_ALL=C awk -v mode="$mode" -v kinds="$f_kind" -v froms="$f_from" -v last="$f_last" -v path="$f_path" -v self="$f_self" -v selected="$selected" \
		-v acked="$f_acked" -v unacked="$f_unacked" -v bytes="$f_bytes" -v brief="$f_brief" '
	BEGIN {
		if (selected != "")
			while ((getline line < selected) > 0)
				chosen[line] = 1
	}
	function add(id, text,    n, line, i, h, key) {
		n = split(text, line, "\n")
		for (i = 1; i < n && line[i] != ""; i++) {
			h = index(line[i], ": ")
			key = substr(line[i], 1, h - 1)
			val[id, key] = substr(line[i], h + 2)
			if (key == "retracts" || key == "supersedes")
				hidden[val[id, key]] = 1
			if (key == "path")
				about[id] = about[id] "\n" val[id, key]
			if (key == "acks")
				acks[id] = acks[id] "\n" val[id, key]
		}
		body[id] = line[i + 1]
		for (i += 2; i < n; i++)
			body[id] = body[id] "\n" line[i]
		order[count++] = id
	}
	skip { skip = 0; next }
	!need {
		if ($2 == "missing")
			next
		need = $1; id = $2; text = ""
		next
	}
	{
		text = text $0 "\n"
		need -= length($0) + 1
		if (need <= 0) {
			add(id, text)
			skip = (need == 0)
			need = 0
		}
	}
	function shown_body(id,    nl) {
		nl = index(body[id], "\n")
		return brief && nl ? substr(body[id], 1, nl - 1) : body[id]
	}
	function acked_by(mid,    n, who, i) {
		n = split(acked, who, ",")
		for (i = 1; i <= n; i++)
			if (index(ackers[mid] ",", "," who[i] ","))
				return 1
		return 0
	}
	function wanted(list, item) {
		return list == "" || index("," list ",", "," item ",")
	}
	function relevant(id,    n, p, i) {
		if (path == "" || about[id] == "")
			return 1
		n = split(about[id], p, "\n")
		for (i = 2; i <= n; i++)
			if (p[i] == path || index(path, p[i] "/") == 1 || index(p[i], path "/") == 1)
				return 1
		return 0
	}
	END {
		for (i = 0; i < count; i++) {
			id = order[i]
			n = split(acks[id], target, "\n")
			for (j = 2; j <= n; j++)
				ackers[target[j]] = ackers[target[j]] "," val[id, "from"]
		}
		for (i = 0; i < count; i++) {
			id = order[i]
			kind = val[id, "kind"]
			if (mode == "ids") {
				if (val[id, "id"] != "")
					print val[id, "id"]
			} else if (mode == "codes") {
				if (val[id, "code"] != "")
					print id, val[id, "code"]
			} else {
				mid = val[id, "id"] != "" ? val[id, "id"] : id
				if (mode == "changes" && kind == "retract" &&
				    (selected == "" || chosen[id]) && (self == "" || val[id, "from"] != self))
					out[nout++] = substr(id, 1, 10) " " val[id, "from"] " retract: " shown_body(id)
				if (kind != "merge" && kind != "retract" && !hidden[mid] &&
				    !shown[mid]++ && (selected == "" || chosen[id]) &&
				    wanted(kinds, kind) && wanted(froms, val[id, "from"]) && relevant(id) &&
				    (self == "" || val[id, "from"] != self) &&
				    (acked == "" || acked_by(mid)) && (!unacked || ackers[mid] == ""))
					out[nout++] = substr(id, 1, 10) " " val[id, "from"] " " kind ": " shown_body(id)
			}
		}
		first = last == "" || nout < last ? 0 : nout - last
		if (bytes != "") {
			used = 0
			for (i = nout - 1; i >= first && used + length(out[i]) + 1 <= bytes; i--)
				used += length(out[i]) + 1
			first = i + 1
		}
		for (i = first; i < nout; i++)
			print out[i]
	}'
}

cmd_init () {
	git config commit.requireContext true &&
	for r in $(git remote)
	do
		cmd_remote $r || exit
	done
}

cmd_remote () {
	git remote get-url "$1" >/dev/null || exit
	for spec in "+refs/cs/heads/*:refs/cs/remotes/$1/*" "refs/cs/pins/*:refs/cs/pins/*" \
		"refs/cs/tags/*:refs/cs/tags/*" "refs/cs/labels/*:refs/cs/labels/*"
	do
		git config --get-all remote."$1".fetch | grep -qxF "$spec" ||
		git config --add remote."$1".fetch "$spec" || exit
	done
}

# The checkpoint a new context branch starts from: cs.base when set, else none.
new_branch_base () {
	base=$(git config cs.base) || return 0
	rev "$base"
}

cmd_commit () {
	branch=$1 message= message_file= kind=message code= expect= root= no_update= onto=
	shift
	while test $# -gt 0
	do
		case "$1" in
		-m) message=$2; message_file=; shift ;;
		-F) message_file=$2; message=$(cat "$2") || exit; shift ;;
		--kind) kind=$2; shift ;;
		--code) code=$2; shift ;;
		--from) from=$2; shift ;;
		--supersedes)
			supersedes=$(rev "$2") &&
			supersedes=$(field $supersedes id) || exit
			test -n "$supersedes" || die "checkpoint has no id: $2"
			shift ;;
		--acks)
			ack=$(rev "$2") &&
			ack=$(field $ack id) || exit
			test -n "$ack" || die "checkpoint has no id: $2"
			acks="$acks$ack
"; shift ;;
		--path) test -n "$2" || usage; paths="$paths$2
"; shift ;;
		--expect) expect=$2; shift ;;
		--root) root=1 ;;
		--no-update) no_update=1 ;;
		--onto) onto=$(rev "$2") || exit; shift ;;
		*) usage ;;
		esac
		shift
	done
	test -z "$onto" || test -n "$no_update" || die "--onto requires --no-update"
	case "$kind" in
	merge|retract) die "kind $kind is reserved for git cs merge and revert" ;;
	esac
	git check-ref-format "$(ref "$branch" 2>/dev/null)" || die "invalid context branch: $branch"
	if test -n "$code"
	then
		code=$(git rev-parse -q --verify "$code^{commit}") || die "not a commit: $code"
	fi
	case "$expect" in
	""|none) ;;
	*) expect=$(rev "$expect") || exit ;;
	esac
	# "--expect none" refuses to write over a branch that someone else created.
	if test -n "$onto"
	then
		tip=$onto
	elif test "$expect" = none
	then
		tip=
	else
		tip=$(git rev-parse -q --verify "$(ref "$branch")")
	fi
	parent=$tip
	test -n "$parent" || test -n "$root" || parent=$(new_branch_base) || exit
	write_message "$kind" "$message"
	commit=$(checkpoint $parent) || exit
	if test -z "$no_update"
	then
		case "$expect" in
		none) old= ;;
		"") old=$tip ;;
		*) old=$expect ;;
		esac
		git update-ref --create-reflog "$(ref "$branch")" $commit "$old" 2>/dev/null || stale
	fi
	echo $commit
}

cmd_show () {
	c=$(rev "$1") || exit
	git cat-file blob $c:message
}

# Every message leading to the checkpoint, oldest first, once per id, without
# merges, retractions and the messages they retract.
cmd_context () {
	c=$(rev "$1") || exit
	shift
	context_options "$@" &&
	read_messages context $c ${since:+^$since}
}

context_options () {
	since= f_kind= f_from= f_last= f_path= f_self= f_acked= f_unacked= f_bytes= f_brief=
	while test $# -gt 0
	do
		case "$1" in
		--since) since=$(rev "$2") || exit; shift ;;
		--last) f_last=$2; shift ;;
		--kind) f_kind=$2; shift ;;
		--from) f_from=$2; shift ;;
		--path) f_path=${2%/}; shift ;;
		--acked-by) test -n "$2" || usage; f_acked=$2; shift ;;
		--unacked) f_unacked=1 ;;
		--max-bytes)
			case "$2" in
			""|*[!0-9]*) die "invalid byte count: $2" ;;
			esac
			f_bytes=$2; shift ;;
		--format)
			case "$2" in
			full) f_brief= ;;
			brief) f_brief=1 ;;
			*) die "unknown format: $2" ;;
			esac
			shift ;;
		*) usage ;;
		esac
		shift
	done
	test -z "$f_acked" || test -z "$f_unacked" || die "--acked-by and --unacked cannot be combined"
}

cmd_sync () {
	me=$1 team=$2
	shift 2
	filtered=$#
	context_options "$@" &&
	tip=$( (branch=$me name=$team noff= message=; merge_once) 2>/dev/null) || die "cannot sync $me with $team"
	seen=$(git rev-parse -q --verify refs/cs/seen/"$me")
	f_self=$from
	read_messages changes $tip ${seen:+^$seen} ${since:+^$since} || return
	test "$filtered" -ne 0 ||
	git update-ref --create-reflog -m "cs sync" refs/cs/seen/"$me" $tip
}

cmd_wait () {
	me=$1 team=$2 waitfor= kinds= timeout=180 start=$(date +%s)
	shift 2
	while test $# -gt 0
	do
		case "$1" in
		--from) waitfor=$2; shift ;;
		--kind) kinds=$2; shift ;;
		--timeout) timeout=$2; shift ;;
		*) usage ;;
		esac
		shift
	done
	test -n "$waitfor" || usage
	while :
	do
		tip=$( (branch=$me name=$team noff= message=; merge_once) 2>/dev/null) || die "cannot sync $me with $team"
		missing=
		for who in $(echo "$waitfor" | tr , ' ')
		do
			f_from=$who f_kind=$kinds f_last= f_path= f_self= f_acked= f_unacked= f_bytes= f_brief=
			test -n "$(read_messages context $tip)" || missing="$missing $who"
		done
		test -n "$missing" || break
		test $(($(date +%s) - start)) -lt $timeout || die "timed out waiting for:$missing"
		echo >&2 "waiting for:$missing"
		sleep 2
	done
	cmd_sync "$me" "$team"
}

# One line per context branch: its tip, the messages it has beyond cs.base
# (or all of them without one), and its newest message.
cmd_heads () {
	base=$(git config cs.base) && base=$(rev "$base") || base=
	git for-each-ref --format='%(refname:strip=3) %(objectname)' refs/cs/heads/ |
	while read -r name tip
	do
		if test -n "$base"
		then
			count=$(git rev-list --count --no-merges $tip ^$base)
		else
			count=$(git rev-list --count --no-merges $tip)
		fi
		echo "$name $(git rev-parse --short=10 $tip) $count $(git log -1 --format='%an %s' $tip)"
	done
}

cmd_log () {
	c=$(rev "$1") || exit
	git log --date=short --format='%h %ad %an %s' $c
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
	printf 'update %s %s\nupdate %s %s %s\n' \
		refs/cs/recovery/"$1" $old "$(ref "$1")" $new $old | transaction
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
	case "$op" in
	add|remove) ;;
	resolve) git for-each-ref --format='%(objectname)' refs/cs/labels/$name/; return ;;
	*) usage ;;
	esac
	: >"$tmp.updates"
	for c in "$@"
	do
		c=$(rev "$c") || exit
		case "$op" in
		add) echo "update refs/cs/labels/$name/$c $c" ;;
		remove) echo "delete refs/cs/labels/$name/$c" ;;
		esac >>"$tmp.updates"
	done
	transaction <"$tmp.updates"
}

# Print a copy of checkpoint $2 on top of $1; a message never conflicts, and
# the copy keeps the message id and author, while its committer records the
# replay.
replay () {
	eval "$(get_author_ident_from_commit $2)" &&
	export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE &&
	git log -1 --format=%B $2 | git commit-tree $2^{tree} -p $1
}

cmd_rebase () {
	old=$(git rev-parse --verify "$(ref "$1")") &&
	new=$(rev "$2") || exit
	if git merge-base --is-ancestor $new $old
	then
		echo >&2 "Already up to date"
		echo $old
		return
	elif git merge-base --is-ancestor $old $new
	then
		git update-ref --create-reflog "$(ref "$1")" $new $old 2>/dev/null || stale
		echo >&2 "Fast-forward"
		echo $new
		return
	fi
	test -z "$(git rev-list --min-parents=2 $new..$old)" || die "cannot replay merge checkpoints"
	read_messages ids "$new" >"$tmp.ids" || exit
	for c in $(git rev-list --reverse $new..$old)
	do
		id=$(field "$c" id)
		if test -n "$id" && grep -qxF "$id" "$tmp.ids"
		then
			continue
		fi
		new=$(replay $new $c) || exit
		test -z "$id" || echo "$id" >>"$tmp.ids"
	done
	printf 'update %s %s\nupdate %s %s %s\n' \
		refs/cs/recovery/"$1" $old "$(ref "$1")" $new $old | transaction 2>/dev/null || stale
	echo $new
}

cmd_cherry_pick () {
	branch=$1 c=$(rev "$2") || exit
	shift 2
	update_options "$@"
	test -n "$onto" || old=$(git rev-parse --verify "$(ref "$branch")") || exit
	new=$(replay ${onto:-$old} $c) || exit
	test -n "$no_update" ||
	git update-ref --create-reflog "$(ref "$branch")" $new $old 2>/dev/null || stale
	echo $new
}

cmd_revert () {
	branch=$1 name=$2 c=$(rev "$2") || exit
	shift 2
	update_options "$@"
	test -n "$onto" || old=$(git rev-parse --verify "$(ref "$branch")") || exit
	case "$(field $c kind)" in
	merge|retract) die "cannot retract a $(field $c kind) checkpoint: $name" ;;
	esac
	retracts=$(field $c id)
	test -n "$retracts" || die "checkpoint has no id: $name"
	write_message retract "Retract: $(git log -1 --format=%s $c)"
	new=$(checkpoint ${onto:-$old}) || exit
	test -n "$no_update" ||
	git update-ref --create-reflog "$(ref "$branch")" $new $old 2>/dev/null || stale
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
	write_message merge "${message:-Merge $name}"
	new=$(checkpoint $ours $theirs) || exit
	git update-ref --create-reflog "$(ref "$branch")" $new $ours 2>/dev/null || stale
	echo >&2 "Merge checkpoint"
	echo $new
}

# Pin or unpin every named checkpoint in one transaction.
cmd_pin () {
	: >"$tmp.updates"
	for c in "$@"
	do
		c=$(rev "$c") || exit
		echo "update refs/cs/pins/$c $c" >>"$tmp.updates"
	done
	transaction <"$tmp.updates"
}

cmd_unpin () {
	: >"$tmp.updates"
	for c in "$@"
	do
		c=$(rev "$c") || exit
		echo "delete refs/cs/pins/$c" >>"$tmp.updates"
	done
	transaction <"$tmp.updates"
}

cmd_commit_code () {
	ctx=$(rev "$2") || exit
	shift 2
	test "$1" = -- && shift
	cmd_pin $ctx &&
	git commit --context $ctx "$@"
}

# Merge each context branch into <branch>, pin the result and make the code
# merge with it as context, so one checkpoint covers every merged contributor.
cmd_integrate () {
	target=$1
	test -n "$target" || usage
	shift
	sources=
	while test $# -gt 0 && test "$1" != --
	do
		sources="$sources $1"
		shift
	done
	test "$1" != -- || shift
	test -n "$sources" || usage
	for source in $sources
	do
		cmd_merge "$target" "$source" --retry 10 >/dev/null || exit
	done
	ctx=$(rev "$target") &&
	cmd_pin $ctx &&
	git merge --context $ctx "$@"
}

code_links () {
	git log --pretty=raw "$@" |
	awk '/^commit / { if (c) print c, n, v; c = $2; n = 0; v = "" }
		/^context / { n++; v = $2 }
		END { if (c) print c, n, v }'
}

cmd_fsck () {
	: >"$tmp.tips"
	bad=$(git for-each-ref --format='%(objectname) %(refname)' refs/cs/ |
	while read -r c name
	do
		if ! is_checkpoint "$c"
		then
			echo "not a checkpoint: $name"
			continue
		fi
		echo "$c" >>"$tmp.tips"
		test -n "$(field $c id)" || echo "missing id: $name"
	done
	git rev-list --stdin <"$tmp.tips" |
	awk 'NR == FNR { tips[$1] = 1; next } !tips[$1]' "$tmp.tips" - |
	while read -r c
	do
		if ! is_checkpoint "$c"
		then
			echo "not a checkpoint: $c"
			continue
		fi
		test -n "$(field $c id)" || echo "missing id: $c"
	done
	read_messages codes $(git for-each-ref --format='%(objectname)' refs/cs/) |
	while read -r c code
	do
		git cat-file -e "$code^{commit}" 2>/dev/null ||
		echo "missing code commit: $c -> $code"
	done
	code_links "${@:---branches}" |
	while read -r code n ctx
	do
		case "$n" in
		(0) echo "unlinked: $code" ;;
		(1)
			if ! is_checkpoint "$ctx"
			then
				echo "link to non-checkpoint: $code -> $ctx"
			else
				git rev-parse -q --verify refs/cs/pins/$ctx >/dev/null ||
				echo "unpinned link: $code -> $ctx"
			fi ;;
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
	remote=$1 heads= code= srcs=
	shift
	while test $# -gt 0
	do
		case "$1" in
		--context)
			git rev-parse -q --verify "$(ref "$2")" >/dev/null || die "no such branch: $2"
			heads="$heads $(ref "$2"):$(ref "$2")"
			shift ;;
		*)
			code="$code $1"
			s=${1#+}
			srcs="$srcs ${s%%:*}" ;;
		esac
		shift
	done
	test -n "$heads" ||
	heads="refs/cs/heads/*:refs/cs/heads/* refs/cs/pins/*:refs/cs/pins/* refs/cs/tags/*:refs/cs/tags/* refs/cs/labels/*:refs/cs/labels/*"
	# A scoped push still sends the pins that the pushed code links to.
	pins=$(test -z "$srcs" || code_links $srcs |
		awk '$2 == 1 { print "refs/cs/pins/" $3 }' | sort -u |
		while read -r p
		do
			git rev-parse -q --verify $p >/dev/null && echo "$p:$p"
		done)
	git push --atomic "$remote" $heads $pins $code
}

cmd_fetch () {
	remote=$1
	test -n "$remote" || usage
	shift
	branches= force=
	while test $# -gt 0
	do
		case "$1" in
		--context)
			test $# -ge 2 && git check-ref-format "refs/cs/heads/$2" || die "invalid context branch: $2"
			branches="$branches $2"
			shift ;;
		--force) force=+ ;;
		*) usage ;;
		esac
		shift
	done
	test -z "$force" || test -n "$branches" || die "--force requires --context"
	if test -n "$branches"
	then
		set --
		for branch in $branches
		do
			tracking="refs/cs/remotes/$remote/$branch"
			if test -n "$force"
			then
				old=$(git rev-parse -q --verify "$tracking" 2>/dev/null)
				test -z "$old" || git update-ref --create-reflog "refs/cs/fetch-recovery/$remote/$branch" "$old" || exit
			fi
			set -- "$@" "${force}refs/cs/heads/$branch:$tracking"
		done
	else
		set -- "refs/cs/heads/*:refs/cs/remotes/$remote/*"
	fi
	git fetch "$remote" "$@" "refs/cs/pins/*:refs/cs/pins/*" "refs/cs/tags/*:refs/cs/tags/*" "refs/cs/labels/*:refs/cs/labels/*"
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
init|remote|commit|show|context|heads|sync|wait|log|diff|branch|switch|reset|reflog|tag|label|merge|rebase|\
cherry-pick|revert|pin|unpin|commit-code|integrate|fsck|links|push|fetch|bundle)
	cmd_$(echo "$cmd" | tr - _) "$@" ;;
*)
	usage ;;
esac
