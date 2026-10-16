#!/bin/bash
# Run one concrete example per git cs command and compare the received outcome with the expected one.
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
	test $v = PASS || echo "      expected: $3" && test $v = PASS || echo "      received: $got"
}
hex () { [[ $1 =~ ^[0-9a-f]{40}$ ]] && echo yes || echo no; }
yn () { "$@" >/dev/null 2>&1 && echo yes || echo no; }
act () { git cs show "$1" | jq -c .active; }
tip () { git rev-parse refs/cs/heads/$1; }
payload () { echo "{\"schema\":\"cs/1\",\"active\":$1,\"chunks\":[{\"id\":\"m1\"},{\"id\":\"m2\"},{\"id\":\"a1\"},{\"id\":\"b1\"}]}" >$P/$2; }
add () { git cs show "$1" | jq --arg id "$2" '.active += [$id] | .chunks += [{id: $id}]' >$P/$3; }
payload '["m1","m2"]' base.json; payload '["m1","m2","a1"]' a.json; payload '["m1","m2","b1"]' b.json
payload '["m2","m1","a1"]' swap.json; payload '["a1"]' result.json

row "commit" "git cs commit main base.json" "id=yes code_head_moved=no worktree_clean=yes" \
	'BASE=$(git cs commit main $P/base.json); echo "id=$(hex $BASE) code_head_moved=$([ $(git rev-parse HEAD) = $H ] && echo no || echo yes) worktree_clean=$([ -z "$(git status --porcelain)" ] && echo yes || echo no)"'
T2=$(git cs commit main $P/base.json --expect $BASE)
row "commit --expect (stale)" "git cs commit main base.json --expect <old tip>" "exit=75 stderr=STALE_TIP tip_unchanged=yes" \
	'git cs commit main $P/base.json --expect $BASE >/dev/null 2>$E; echo "exit=$? stderr=$(cat $E) tip_unchanged=$([ $(tip main) = $T2 ] && echo yes || echo no)"'
row "commit (invalid payload)" "git cs commit main dup.json  (chunk id m1 twice)" "exit=1 stderr=invalid cs/1 payload: dup.json" \
	'echo "{\"schema\":\"cs/1\",\"active\":[\"m1\"],\"chunks\":[{\"id\":\"m1\"},{\"id\":\"m1\",\"body\":\"x\"}]}" >$P/dup.json; git cs commit main $P/dup.json >/dev/null 2>$E; echo "exit=$? stderr=$(sed "s|$P/||" $E)"'
row "commit (identity conflict)" "git cs commit main changed.json  (m1 with new bytes)" "exit=1 stderr=identity conflict: m1" \
	'echo "{\"schema\":\"cs/1\",\"active\":[\"m1\"],\"chunks\":[{\"id\":\"m1\",\"body\":\"new\"}]}" >$P/changed.json; git cs commit main $P/changed.json >/dev/null 2>$E; echo "exit=$? stderr=$(cat $E)"'
row "commit (escaped bytes)" "git cs commit esc esc.json  (body with \\n and \\\\)" "bytes_equal=yes" \
	'printf "%s\n" "{\"schema\":\"cs/1\",\"active\":[\"e\"],\"chunks\":[{\"id\":\"e\",\"body\":\"a\\\\nb \\\\\\\\t\"}]}" >$P/esc.json; e=$(git cs commit esc $P/esc.json); echo "bytes_equal=$([ "$(jq -cS .chunks $P/esc.json)" = "$(git cs show $e | jq -cS .chunks)" ] && echo yes || echo no)"'
row "commit -m" "git cs commit notes -m 'Investigate SQLite'; git cs commit notes -m 'Use WAL mode' --kind learning" "chunks=2 kinds=message,learning subject=Use WAL mode" \
	'git cs commit notes -m "Investigate SQLite" >/dev/null; git cs commit notes -m "Use WAL mode" --kind learning >/dev/null; echo "chunks=$(git cs show notes | jq ".active | length") kinds=$(git cs show notes --messages | sed -E "s/^m[0-9a-f]+ ([a-z]+):.*/\1/" | paste -sd, -) subject=$(git log -1 --format=%s refs/cs/heads/notes)"'
row "show --messages" "git cs show notes --messages" "<id> message: Investigate SQLite <id> learning: Use WAL mode" \
	'git cs show notes --messages | sed -E "s/^m[0-9a-f]+/<id>/"'
row "--json (success)" "git cs --json commit main base.json" '{"ok":true,"id":true}' \
	'git cs --json commit main $P/base.json | jq -c "{ok, id: (.output | test(\"^[0-9a-f]{40}$\"))}"'
row "--json (failure)" "git cs --json commit main base.json --expect <old tip>" '{"ok":false,"error":"STALE_TIP"}' \
	'git cs --json commit main $P/base.json --expect $BASE | jq -c "{ok, error}"'
row "show" "git cs show <base>" '{"active":["m1","m2"],"chunks":4}' \
	'git cs show $BASE | jq -c "{active, chunks: (.chunks | length)}"'
row "show (round-trip)" "git cs show <base> > rt.json; git cs commit rt rt.json" "same_tree=yes" \
	'git cs show $BASE >$P/rt.json; r=$(git cs commit rt $P/rt.json); echo "same_tree=$([ $(git rev-parse $r^{tree}) = $(git rev-parse $BASE^{tree}) ] && echo yes || echo no)"'
row "show (bare name)" "git cs show main  (code branch main also exists)" "resolves_to=context" \
	'echo "resolves_to=$([ "$(git cs show main)" = "$(git cs show refs/cs/heads/main)" ] && echo context || echo code)"'
git cs branch logb $BASE; git cs commit logb $P/a.json >/dev/null
row "log" "git cs log logb" "<id> <date> cs checkpoint | + a1 | <id> <date> cs checkpoint | + m1 | + m2" \
	'git cs log logb | sed -E "s/^[0-9a-f]{7,} [0-9-]{10}/<id> <date>/; s/^ +//" | paste -sd"|" - | sed "s/|/ | /g"'
row "diff" "git cs diff <base> <swap>  (swap = m2,m1,a1)" "+ a1 ~ reordered" \
	'git cs branch swap $BASE; git cs commit swap $P/swap.json >/dev/null; git cs diff $BASE swap'
row "branch" "git cs branch agent-a <base>" "created_at_base=yes" \
	'git cs branch agent-a $BASE && echo "created_at_base=$([ $(tip agent-a) = $BASE ] && echo yes || echo no)"'
row "branch (exists)" "git cs branch agent-a <base> again" "refused=yes" \
	'echo "refused=$(git cs branch agent-a $BASE >/dev/null 2>&1 && echo no || echo yes)"'
git cs branch agent-b $BASE; A=$(git cs commit agent-a $P/a.json); B=$(git cs commit agent-b $P/b.json)
git cs branch union $A
row "merge (union)" "git cs merge union agent-b" 'active=["m1","m2","a1","b1"] parents=2 stderr=Merge checkpoint' \
	'U=$(git cs merge union agent-b 2>$E); echo "active=$(act $U) parents=$(git rev-list --parents -1 $U | wc -w | tr -d " " | awk "{print \$1-1}") stderr=$(cat $E)"'
git cs branch ff $BASE
row "merge (fast-forward)" "git cs merge ff agent-a" "stderr=Fast-forward tip=agent-a" \
	'o=$(git cs merge ff agent-a 2>$E); echo "stderr=$(cat $E) tip=$([ $o = $A ] && [ $(tip ff) = $A ] && echo agent-a)"'
row "merge (up to date)" "git cs merge ff <base>" "stderr=Already up to date printed=current_tip" \
	'o=$(git cs merge ff $BASE 2>$E); echo "stderr=$(cat $E) printed=$([ $o = $A ] && echo current_tip)"'
git cs branch noff $BASE
row "merge --no-ff" "git cs merge noff agent-a --no-ff" 'parents=2 active=["m1","m2","a1"] stderr=Merge checkpoint' \
	'o=$(git cs merge noff agent-a --no-ff 2>$E); echo "parents=$(git rev-list --parents -1 $o | awk "{print NF-1}") active=$(act $o) stderr=$(cat $E)"'
git cs branch res $A
row "merge --result" "git cs merge res agent-b --result result.json" 'active=["a1"] parents=2' \
	'o=$(git cs merge res agent-b --result $P/result.json 2>/dev/null); echo "active=$(act $o) parents=$(git rev-list --parents -1 $o | awk "{print NF-1}")"'
row "merge (order conflict)" "git cs merge agent-a swap  (m1,m2 vs m2,m1)" "refused=yes msg=order conflict tip_unchanged=yes" \
	'git cs merge agent-a swap >/dev/null 2>$E; echo "refused=$([ $? -ne 0 ] && echo yes) msg=$(grep -o "order conflict" $E) tip_unchanged=$([ $(tip agent-a) = $A ] && echo yes)"'
echo "{\"schema\":\"cs/1\",\"active\":[\"m1\"],\"chunks\":[{\"id\":\"m1\",\"body\":\"other\"}]}" >$P/root.json; git cs commit rootb $P/root.json >/dev/null
row "merge (identity conflict)" "git cs merge agent-a rootb  (unrelated m1 bytes)" "refused=yes msg=identity conflict: m1" \
	'git cs merge agent-a rootb >/dev/null 2>$E; echo "refused=$([ $? -ne 0 ] && echo yes) msg=$(grep -o "identity conflict: m1" $E)"'
row "merge-preview" "git cs merge-preview agent-a agent-b" 'active=["m1","m2","a1","b1"] refs_moved=no' \
	'pv=$(git cs merge-preview agent-a agent-b); echo "active=$(echo "$pv" | jq -c .active) refs_moved=$([ $(tip agent-a) = $A ] && [ $(tip agent-b) = $B ] && echo no || echo yes)"'
for mode in 0 20; do
	git cs branch s$mode $BASE
	for i in 1 2 3 4 5 6 7 8; do git cs branch q$mode-$i $BASE; add $BASE q$mode-$i q$i.json; git cs commit q$mode-$i $P/q$i.json >/dev/null; done
done
row "merge (8 parallel, no --retry)" "8x: git cs merge s0 q0-N &" "landed=1/8 exit75=7" \
	'for i in 1 2 3 4 5 6 7 8; do (git cs merge s0 q0-$i >/dev/null 2>&1; echo $? >$P/rc$i) & done; wait; echo "landed=$(git cs show s0 | jq "[.active[] | select(startswith(\"q0-\"))] | length")/8 exit75=$(grep -l "^75$" $P/rc* | wc -l | tr -d " ")"'
row "merge --retry (8 parallel)" "8x: git cs merge s20 q20-N --retry 20 &" "landed=8/8 exit0=8" \
	'for i in 1 2 3 4 5 6 7 8; do (git cs merge s20 q20-$i --retry 20 >/dev/null 2>&1; echo $? >$P/rc$i) & done; wait; echo "landed=$(git cs show s20 | jq "[.active[] | select(startswith(\"q20-\"))] | length")/8 exit0=$(grep -l "^0$" $P/rc* | wc -l | tr -d " ")"'
git cs branch race $BASE
row "commit (8 parallel, same tip)" "8x: git cs commit race rN.json --expect <tip> &" "succeeded=1 exit75=7" \
	'for i in 1 2 3 4 5 6 7 8; do add $BASE r$i r$i.json; done; for i in 1 2 3 4 5 6 7 8; do (git cs commit race $P/r$i.json --expect $BASE >/dev/null 2>&1; echo $? >$P/rc$i) & done; wait; echo "succeeded=$(grep -l "^0$" $P/rc* | wc -l | tr -d " ") exit75=$(grep -l "^75$" $P/rc* | wc -l | tr -d " ")"'
git cs branch topic $BASE; git cs commit topic $P/a.json >/dev/null; TOPIC=$(tip topic)
row "rebase" "git cs rebase topic agent-b" 'active=["m1","m2","a1","b1"] on_agent-b=yes recovery=old_tip' \
	'git cs rebase topic agent-b >/dev/null; echo "active=$(act topic) on_agent-b=$(yn git merge-base --is-ancestor $B refs/cs/heads/topic) recovery=$([ $(git rev-parse refs/cs/recovery/topic) = $TOPIC ] && echo old_tip)"'
payload '["m1"]' drop.json; git cs branch dropper $BASE; git cs commit dropper $P/drop.json >/dev/null
payload '["m1","b1"]' drop2.json; git cs branch up $BASE; git cs commit up $P/drop2.json >/dev/null
row "rebase (conflict)" "git cs rebase dropper up  (both removed m2)" "refused=yes msg=replay conflict tip_unchanged=yes" \
	'd=$(tip dropper); git cs rebase dropper up >/dev/null 2>$E; echo "refused=$([ $? -ne 0 ] && echo yes) msg=$(grep -o "replay conflict" $E) tip_unchanged=$([ $(tip dropper) = $d ] && echo yes)"'
row "rebase (merge checkpoints)" "git cs rebase union <base>" "refused=yes msg=cannot replay merge checkpoints" \
	'git cs rebase union $BASE >/dev/null 2>$E; echo "refused=$([ $? -ne 0 ] && echo yes) msg=$(cat $E)"'
git cs branch pick $BASE
row "cherry-pick" "git cs cherry-pick pick agent-b" 'active=["m1","m2","b1"]' \
	'git cs cherry-pick pick agent-b >/dev/null; echo "active=$(act pick)"'
row "revert" "git cs revert pick pick" 'active=["m1","m2"]' \
	'git cs revert pick pick >/dev/null; echo "active=$(act pick)"'
row "reset" "git cs reset agent-a <base>" "tip=base recovery=old_tip" \
	'git cs reset agent-a $BASE; echo "tip=$([ $(tip agent-a) = $BASE ] && echo base) recovery=$([ $(git rev-parse refs/cs/recovery/agent-a) = $A ] && echo old_tip)"'
row "reset (code commit)" "git cs reset agent-a HEAD" "refused=yes stderr=not a cs checkpoint: HEAD" \
	'git cs reset agent-a HEAD 2>$E; echo "refused=$([ $? -ne 0 ] && echo yes) stderr=$(cat $E)"'
row "reflog" "git cs reflog agent-a" "entries=3" \
	'echo "entries=$(git cs reflog agent-a | wc -l | tr -d " ")"'
row "branch --through" "git cs branch cut union --through m2" 'active=["m1","m2"] subject=cs derived view: prefix through m2' \
	'git cs branch cut union --through m2; echo "active=$(act cut) subject=$(git log -1 --format=%s refs/cs/heads/cut)"'
row "switch" "git cs switch -c w1 wb <base>; git cs commit @w1 a.json" 'workspace=refs/cs/heads/wb wb_active=["m1","m2","a1"]' \
	'git cs switch -c w1 wb $BASE; git cs commit @w1 $P/a.json >/dev/null; echo "workspace=$(git symbolic-ref refs/cs/workspaces/w1) wb_active=$(act wb)"'
row "tag" "git cs tag v1 union; git cs tag v1 agent-b" "created=yes move_refused=yes" \
	'echo "created=$(yn git cs tag v1 union) move_refused=$(git cs tag v1 agent-b >/dev/null 2>&1 && echo no || echo yes)"'
row "label" "git cs label add sprint agent-b union; remove sprint union" "after_add=2 after_remove=1" \
	'git cs label add sprint agent-b union; a=$(git cs label resolve sprint | wc -l | tr -d " "); git cs label remove sprint union; echo "after_add=$a after_remove=$(git cs label resolve sprint | wc -l | tr -d " ")"'
row "pin / unpin" "git cs pin agent-b; git cs unpin agent-b" "pinned=yes unpinned=yes" \
	'git cs pin agent-b; p=$(yn git rev-parse -q --verify refs/cs/pins/$B); git cs unpin agent-b; echo "pinned=$p unpinned=$(git rev-parse -q --verify refs/cs/pins/$B >/dev/null && echo no || echo yes)"'
U=$(tip union)
row "commit-code" "git cs commit-code --context union -- -m 'Add g'" "link=union pinned=yes trailers=1" \
	'echo g >g && git add g && git cs commit-code --context union -- -q -m "Add g"; echo "link=$([ "$(git cs links --code HEAD)" = $U ] && echo union) pinned=$(yn git rev-parse -q --verify refs/cs/pins/$U) trailers=$(git log -1 --format=%B | grep -c "^Context-Shadow:")"'
row "commit-code (amend relink)" "git cs commit-code --context agent-b -- --amend --no-edit" "link=agent-b trailers=1" \
	'git cs commit-code --context agent-b -- -q --amend --no-edit; echo "link=$([ "$(git cs links --code HEAD)" = $B ] && echo agent-b) trailers=$(git log -1 --format=%B | grep -c "^Context-Shadow:")"; git cs commit-code --context union -- -q --amend --no-edit'
row "links --code" "git cs links --code HEAD" "union" \
	'[ "$(git cs links --code HEAD)" = $U ] && echo union'
row "links --context" "git cs links --context union" "HEAD" \
	'[ "$(git cs links --context union)" = "$(git rev-parse HEAD)" ] && echo HEAD'
row "fsck" "git cs fsck HEAD~1..HEAD; git cs fsck" "range=clean full=flags_unlinked_code_commit" \
	'echo "range=$(git cs fsck HEAD~1..HEAD >/dev/null 2>&1 && echo clean) full=$(git cs fsck 2>&1 | grep -q "unlinked: $H" && echo flags_unlinked_code_commit)"'
row "install-hook" "git cs install-hook; git commit -m plain; git cs commit-code ..." "plain=rejected linked=accepted" \
	'git cs install-hook; echo "plain=$(git commit -q --allow-empty -m plain >/dev/null 2>&1 && echo accepted || echo rejected) linked=$(git cs commit-code --context union -- -q --allow-empty -m linked >/dev/null 2>&1 && echo accepted || echo rejected)"'
row "gc survival" "delete branch union; git gc --prune=now; git cs show <union>" "readable=yes" \
	'git update-ref -d refs/cs/heads/union; git gc -q --prune=now; echo "readable=$(yn git cs show $U)"'
row "push" "git cs push origin main" "pushed=yes remote_has_context=yes" \
	'echo "pushed=$(yn git cs push origin main) remote_has_context=$(yn git -C ../hub.git rev-parse refs/cs/heads/main)"'
row "push (atomic refusal)" "remote main diverged; git cs push origin main" "refused=yes remote_context_unchanged=yes" \
	'git push -q -f origin $(git commit-tree HEAD^{tree} -m other):refs/heads/main; before=$(git -C ../hub.git rev-parse refs/cs/heads/agent-b); git cs commit agent-b $P/base.json >/dev/null; git cs push origin main >/dev/null 2>&1; echo "refused=$([ $? -ne 0 ] && echo yes) remote_context_unchanged=$([ $(git -C ../hub.git rev-parse refs/cs/heads/agent-b) = $before ] && echo yes)"; git push -q -f origin main'
row "fetch" "git clone hub rx; git cs fetch origin" "links_resolve=yes fsck=clean" \
	'git cs push origin main >/dev/null 2>&1; git clone -q ../hub.git ../rx; (cd ../rx && git cs fetch origin >/dev/null 2>&1 && echo "links_resolve=$(yn git cs show $(git cs links --code HEAD)) fsck=$(git cs fsck HEAD~2..HEAD >/dev/null 2>&1 && echo clean)")'
row "bundle" "git cs bundle ctx.bundle main; fetch into empty repo" "links_resolve=yes" \
	'git cs bundle $P/ctx.bundle main >/dev/null 2>&1; git init -q ../offline; git -C ../offline fetch -q $P/ctx.bundle "refs/cs/*:refs/cs/*" main:in; echo "links_resolve=$(yn git -C ../offline cs show $(git -C ../offline cs links --code in))"'
row "temp files" "ls .git after all runs" "left=0" \
	'echo "left=$(ls .git | grep -c cs-tmp)"'
{
	echo "| cmd | testing example done | expected outcome | received outcome | result |"
	echo "|---|---|---|---|---|"
	awk -F'\t' '{ printf "| %s | `%s` | %s | %s | %s |\n", $1, $2, $3, $4, $5 }' $OUT
} >$SB/cmdtable.md
echo "passed=$(grep -c "	PASS$" $OUT) failed=$(grep -c "	FAIL$" $OUT) table=$SB/cmdtable.md"
! grep -q "	FAIL$" $OUT
