#!/bin/bash
# Run one concrete example per git cs primitive and compare the received outcome with the expected one.
#
# Usage: cs-testing/cmdtable.sh   (after `make` in the repository root)
# Uses the freshly built git from bin-wrappers/ unless CS_GIT_BIN points elsewhere,
# and works in a throwaway directory unless CS_SANDBOX is set.
# Writes <sandbox>/cmdtable.tsv and <sandbox>/cmdtable.md and exits non-zero on any FAIL.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH="${CS_GIT_BIN:-$ROOT/bin-wrappers}:$PATH"
SB=${CS_SANDBOX:-$(mktemp -d "${TMPDIR:-/tmp}/cs-testing.XXXXXX")}
W=$SB/cmdtable P=$SB/cmdtable/p OUT=$SB/cmdtable.tsv E=$SB/cmdtable/p/err
rm -rf $W $OUT && mkdir -p $P && cd $W
git init -q --bare -b main hub.git
git init -q -b main app && cd app && echo code >f && git add f && git commit -q -m code && git remote add origin ../hub.git
H=$(git rev-parse HEAD)

row () {
	eval "$4" >$P/out 2>/dev/null
	got=$(tr '\n' ' ' <$P/out | sed 's/ *$//')
	v=FAIL; test "$got" = "$3" && v=PASS
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$got" "$v" >>$OUT
	echo "$v  $1: $2"
	test $v = PASS || { echo "      expected: $3"; echo "      received: $got"; }
}
yn () { "$@" >/dev/null 2>&1 && echo yes || echo no; }
tip () { git rev-parse refs/cs/heads/$1; }
ctx () { git cs context "$1" | sed -E 's/^[0-9a-f]+ //' | paste -sd'|' -; }
kind () { git cs show "$1" | sed -n '1s/^kind: //p'; }
parents () { git rev-list --parents -1 "$1" | awk '{ print NF - 1 }'; }
link () { git cat-file commit "$1" | sed -n '/^$/q; s/^context //p'; }

row "commit -m" "git cs commit main -m 'Investigate SQLite'" "tree=message code_head_moved=no worktree_clean=yes" \
	'BASE=$(git cs commit main -m "Investigate SQLite"); echo "tree=$(git ls-tree --name-only $BASE) code_head_moved=$([ $(git rev-parse HEAD) = $H ] && echo no || echo yes) worktree_clean=$([ -z "$(git status --porcelain)" ] && echo yes || echo no)"'
row "show" "git cs show main" "kind: message  Investigate SQLite" \
	'git cs show main | sed "/^id: /d"'
row "commit --kind --code" "git cs commit main -m 'Use WAL mode' --kind learning --code HEAD" "kind=learning code=HEAD subject=learning: Use WAL mode" \
	'c=$(git cs commit main -m "Use WAL mode" --kind learning --code HEAD); echo "kind=$(kind $c) code=$([ "$(git cs show $c | sed -n "s/^code: //p")" = $H ] && echo HEAD) subject=$(git log -1 --format=%s $c)"'
row "commit -F (escapes)" "git cs commit esc -F msg  (body with \\n and \\\\)" "bytes_equal=yes" \
	'printf "line one\nback\\\\slash \\\\n literal\n" >$P/msg; e=$(git cs commit esc -F $P/msg); echo "bytes_equal=$([ "$(git cs show $e | sed "1,/^\$/d")" = "$(cat $P/msg)" ] && echo yes || echo no)"'
T2=$(tip main)
row "commit --expect (stale)" "git cs commit main -m late --expect <old tip>" "exit=75 stderr=STALE_TIP tip_unchanged=yes" \
	'git cs commit main -m newer --expect $T2 >/dev/null; T3=$(tip main); git cs commit main -m late --expect $T2 >/dev/null 2>$E; echo "exit=$? stderr=$(cat $E) tip_unchanged=$([ $(tip main) = $T3 ] && echo yes)"'
row "commit (invalid input)" "bad kind / --code nope / empty message" "bad_kind=refused bad_code=refused empty=refused" \
	'echo "bad_kind=$(git cs commit main -m x --kind "Bad Kind" >/dev/null 2>&1 && echo accepted || echo refused) bad_code=$(git cs commit main -m x --code nope >/dev/null 2>&1 && echo accepted || echo refused) empty=$(git cs commit main -m "" >/dev/null 2>&1 && echo accepted || echo refused)"'
row "context" "git cs context main" "message: Investigate SQLite|learning: Use WAL mode|message: newer" \
	'ctx main'
row "log" "git cs log main" "3 lines, newest=message: newer" \
	'echo "$(git cs log main | wc -l | tr -d " ") lines, newest=$(git cs log main | head -1 | cut -d" " -f3-)"'
row "show (bare name)" "git cs show main  (code branch main also exists)" "resolves_to=context" \
	'echo "resolves_to=$([ "$(git cs show main)" = "$(git cs show refs/cs/heads/main)" ] && echo context || echo code)"'
row "diff" "git cs diff <base> main" "+ message: newer + learning: Use WAL mode" \
	'git cs diff $BASE main | sed -E "s/ [0-9a-f]+ / /"'
row "branch" "git cs branch agent-a <base>; again" "created_at_base=yes second=refused" \
	'git cs branch agent-a $BASE; echo "created_at_base=$([ $(tip agent-a) = $BASE ] && echo yes) second=$(git cs branch agent-a $BASE >/dev/null 2>&1 && echo accepted || echo refused)"'
row "switch" "git cs switch -c w1 wb <base>; git cs commit @w1 -m hi" "workspace=refs/cs/heads/wb context=message: Investigate SQLite|message: hi" \
	'git cs switch -c w1 wb $BASE; git cs commit @w1 -m hi >/dev/null; echo "workspace=$(git symbolic-ref refs/cs/workspaces/w1) context=$(ctx wb)"'
row "reset" "git cs reset wb <base>" "tip=base recovery=old_tip" \
	'old=$(tip wb); git cs reset wb $BASE; echo "tip=$([ $(tip wb) = $BASE ] && echo base) recovery=$([ $(git rev-parse refs/cs/recovery/wb) = $old ] && echo old_tip)"'
row "reset (code commit)" "git cs reset wb HEAD" "refused=yes stderr=not a cs checkpoint: HEAD" \
	'git cs reset wb HEAD 2>$E; echo "refused=$([ $? -ne 0 ] && echo yes) stderr=$(cat $E)"'
row "reflog" "git cs reflog wb" "entries=3" \
	'echo "entries=$(git cs reflog wb | wc -l | tr -d " ")"'
row "tag" "git cs tag v1 main; git cs tag v1 <base>" "created=yes move_refused=yes" \
	'echo "created=$(yn git cs tag v1 main) move_refused=$(git cs tag v1 $BASE >/dev/null 2>&1 && echo no || echo yes)"'
row "label" "git cs label add sprint <base> main; remove sprint <base>" "after_add=2 after_remove=1" \
	'git cs label add sprint $BASE main; a=$(git cs label resolve sprint | wc -l | tr -d " "); git cs label remove sprint $BASE; echo "after_add=$a after_remove=$(git cs label resolve sprint | wc -l | tr -d " ")"'
git cs branch agent-b $BASE; git cs commit agent-a -m "from a" >/dev/null; git cs commit agent-b -m "from b" >/dev/null; A=$(tip agent-a)
git cs branch ff $BASE
row "merge (fast-forward)" "git cs merge ff agent-a" "stderr=Fast-forward tip=agent-a" \
	'o=$(git cs merge ff agent-a 2>$E); echo "stderr=$(cat $E) tip=$([ $o = $A ] && [ $(tip ff) = $A ] && echo agent-a)"'
row "merge (up to date)" "git cs merge ff <base>" "stderr=Already up to date printed=current_tip" \
	'o=$(git cs merge ff $BASE 2>$E); echo "stderr=$(cat $E) printed=$([ $o = $A ] && echo current_tip)"'
row "merge (checkpoint)" "git cs merge agent-a agent-b" "stderr=Merge checkpoint kind=merge parents=2 context=message: Investigate SQLite|message: from a|message: from b" \
	'm=$(git cs merge agent-a agent-b 2>$E); echo "stderr=$(cat $E) kind=$(kind $m) parents=$(parents $m) context=$(git cs context agent-a | sed -E "s/^[0-9a-f]+ //" | sort | paste -sd"|" -)"'
git cs branch noff $BASE
row "merge --no-ff -m" "git cs merge noff agent-b --no-ff -m 'take b'" "parents=2 body=take b" \
	'm=$(git cs merge noff agent-b --no-ff -m "take b" 2>/dev/null); echo "parents=$(parents $m) body=$(git cs show $m | sed "1,/^\$/d")"'
for mode in 0 20; do
	git cs branch s$mode $BASE
	for i in 1 2 3 4 5 6 7 8; do git cs branch q$mode-$i $BASE; git cs commit q$mode-$i -m "q$mode-$i" >/dev/null; done
done
row "merge (8 parallel, no --retry)" "8x: git cs merge s0 q0-N &" "landed=1/8 exit75=7" \
	'for i in 1 2 3 4 5 6 7 8; do (git cs merge s0 q0-$i >/dev/null 2>&1; echo $? >$P/rc$i) & done; wait; echo "landed=$(git cs context s0 | grep -c " q0-")/8 exit75=$(grep -l "^75$" $P/rc* | wc -l | tr -d " ")"'
row "merge --retry (8 parallel)" "8x: git cs merge s20 q20-N --retry 20 &" "landed=8/8 exit0=8" \
	'for i in 1 2 3 4 5 6 7 8; do (git cs merge s20 q20-$i --retry 20 >/dev/null 2>&1; echo $? >$P/rc$i) & done; wait; echo "landed=$(git cs context s20 | grep -c " q20-")/8 exit0=$(grep -l "^0$" $P/rc* | wc -l | tr -d " ")"'
git cs branch race $BASE
row "commit (8 parallel, same tip)" "8x: git cs commit race -m rN --expect <tip> &" "succeeded=1 exit75=7" \
	'for i in 1 2 3 4 5 6 7 8; do (git cs commit race -m r$i --expect $BASE >/dev/null 2>&1; echo $? >$P/rc$i) & done; wait; echo "succeeded=$(grep -l "^0$" $P/rc* | wc -l | tr -d " ") exit75=$(grep -l "^75$" $P/rc* | wc -l | tr -d " ")"'
git cs branch topic $BASE; git cs commit topic -m t1 >/dev/null; git cs commit topic -m t2 >/dev/null; TOPIC=$(tip topic)
row "rebase" "git cs rebase topic agent-b" "context=message: Investigate SQLite|message: from b|message: t1|message: t2 recovery=old_tip" \
	'git cs rebase topic agent-b >/dev/null; echo "context=$(ctx topic) recovery=$([ $(git rev-parse refs/cs/recovery/topic) = $TOPIC ] && echo old_tip)"'
row "rebase (merge checkpoints)" "git cs rebase agent-a <base>" "refused=yes stderr=cannot replay merge checkpoints" \
	'git cs rebase agent-a $BASE >/dev/null 2>$E; echo "refused=$([ $? -ne 0 ] && echo yes) stderr=$(cat $E)"'
git cs branch pick $BASE
row "cherry-pick" "git cs cherry-pick pick topic" "context=message: Investigate SQLite|message: t2" \
	'git cs cherry-pick pick topic >/dev/null; echo "context=$(ctx pick)"'
row "revert" "git cs revert pick pick" "kind=retract context=message: Investigate SQLite" \
	'git cs revert pick pick >/dev/null; echo "kind=$(kind pick) context=$(ctx pick)"'
row "pin / unpin" "git cs pin topic; git cs unpin topic" "pinned=yes unpinned=yes" \
	'git cs pin topic; T=$(tip topic); p=$(yn git rev-parse -q --verify refs/cs/pins/$T); git cs unpin topic; echo "pinned=$p unpinned=$(git rev-parse -q --verify refs/cs/pins/$T >/dev/null && echo no || echo yes)"'
row "init" "git cs init; git commit -m unlinked" "requireContext=true plain_commit=refused" \
	'git cs init; echo x >>f; git add f; echo "requireContext=$(git config commit.requireContext) plain_commit=$(git commit -q -m unlinked >/dev/null 2>&1 && echo accepted || echo refused)"'
M=$(tip main)
row "commit-code" "git cs commit-code --context main -- -m 'Add x'" "header=main pinned=yes headers=1" \
	'git cs commit-code --context main -- -q -m "Add x"; echo "header=$([ "$(link HEAD)" = $M ] && echo main) pinned=$(yn git rev-parse -q --verify refs/cs/pins/$M) headers=$(git cat-file commit HEAD | sed "/^$/q" | grep -c "^context ")"'
row "git commit --amend" "git commit --amend -m reworded" "link_kept=yes" \
	'git commit -q --amend -m reworded; echo "link_kept=$([ "$(link HEAD)" = $M ] && echo yes)"'
row "git commit --amend --context" "git commit --amend --context agent-b ...  (via full id)" "header=agent-b headers=1" \
	'git cs pin agent-b; git commit -q --amend --no-edit --context $(tip agent-b); echo "header=$([ "$(link HEAD)" = $(tip agent-b) ] && echo agent-b) headers=$(git cat-file commit HEAD | sed "/^$/q" | grep -c "^context ")"; git commit -q --amend --no-edit --context $M'
row "links --code" "git cs links --code HEAD" "main" \
	'[ "$(git cs links --code HEAD)" = $M ] && echo main'
row "links --context" "git cs links --context main" "HEAD" \
	'[ "$(git cs links --context main)" = "$(git rev-parse HEAD)" ] && echo HEAD'
git checkout -q -b side HEAD~1; echo s >s; git add s; git cs commit-code --context agent-b -- -q -m side-change; SIDE=$(git rev-parse HEAD); git checkout -q main
row "git cherry-pick (code)" "git cherry-pick side  (side commit linked to agent-b)" "link=agent-b" \
	'git cherry-pick $SIDE >/dev/null 2>&1; echo "link=$([ "$(link HEAD)" = $(tip agent-b) ] && echo agent-b)"'
row "git rebase (code)" "git rebase main side" "link=agent-b" \
	'git rebase -q main side >/dev/null 2>&1; echo "link=$([ "$(link side)" = $(tip agent-b) ] && echo agent-b)"; git checkout -q main'
row "fsck" "git cs fsck $H..main; git cs fsck" "range=clean full=flags_unlinked_root" \
	'echo "range=$(git cs fsck $H..main >/dev/null 2>&1 && echo clean) full=$(git cs fsck 2>&1 | grep -q "unlinked: $H" && echo flags_unlinked_root)"'
row "gc survival" "delete branch main; git gc --prune=now; git cs show <main>" "readable=yes" \
	'git update-ref -d refs/cs/heads/main; git gc -q --prune=now; echo "readable=$(yn git cs show $M)"; git cs branch main $M'
row "push" "git cs push origin main" "pushed=yes remote_has_context=yes" \
	'echo "pushed=$(yn git cs push origin main) remote_has_context=$(yn git -C ../hub.git rev-parse refs/cs/heads/main)"'
row "push (atomic refusal)" "remote main diverged; git cs push origin main" "refused=yes remote_context_unchanged=yes" \
	'git push -q -f origin $(git commit-tree HEAD^{tree} -m other):refs/heads/main; before=$(git -C ../hub.git rev-parse refs/cs/heads/agent-b); git cs commit agent-b -m newer >/dev/null; git cs push origin main >/dev/null 2>&1; echo "refused=$([ $? -ne 0 ] && echo yes) remote_context_unchanged=$([ $(git -C ../hub.git rev-parse refs/cs/heads/agent-b) = $before ] && echo yes)"; git push -q -f origin main'
row "fetch" "git clone hub rx; git cs fetch origin" "links_resolve=yes fsck=clean" \
	'git cs push origin main >/dev/null 2>&1; git clone -q ../hub.git ../rx; (cd ../rx && git cs fetch origin >/dev/null 2>&1 && echo "links_resolve=$(yn git cs show $(git cs links --code HEAD)) fsck=$(git cs fsck HEAD~1..HEAD >/dev/null 2>&1 && echo clean)")'
row "bundle" "git cs bundle ctx.bundle main; fetch into empty repo" "links_resolve=yes" \
	'git cs bundle $P/ctx.bundle main >/dev/null 2>&1; git init -q ../offline; git -C ../offline fetch -q $P/ctx.bundle "refs/cs/*:refs/cs/*" main:in; echo "links_resolve=$(yn git -C ../offline cs show $(git -C ../offline cs links --code in))"'
row "no JSON" "grep jq in the installed git-cs" "jq_calls=0" \
	'echo "jq_calls=$(grep -c "jq " "$(git --exec-path)/git-cs")"'
row "temp files" "ls .git after all runs" "left=0" \
	'echo "left=$(ls .git | grep -c cs-tmp)"'
{
	echo "| cmd | testing example done | expected outcome | received outcome | result |"
	echo "|---|---|---|---|---|"
	awk -F'\t' '{ printf "| %s | `%s` | %s | %s | %s |\n", $1, $2, $3, $4, $5 }' $OUT
} >$SB/cmdtable.md
echo "passed=$(grep -c "	PASS$" $OUT) failed=$(grep -c "	FAIL$" $OUT) table=$SB/cmdtable.md"
! grep -q "	FAIL$" $OUT
