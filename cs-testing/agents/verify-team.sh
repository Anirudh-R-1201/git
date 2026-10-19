#!/bin/bash
set -e
# Usage: verify-team.sh <sandbox>
# After the agents finish: check the shared context, merge their code with linked merge
# commits, run the tests, and prove a fresh clone resolves every link.
SB=${1:?usage: verify-team.sh <sandbox>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PATH="${CS_GIT_BIN:-$ROOT/bin-wrappers}:$PATH"
cd "$SB/team" && base=$(git rev-parse HEAD)
echo "team context: $(git cs log main | grep -vc ' merge: ') messages," \
	"$(git rev-list refs/cs/heads/main | wc -l | tr -d ' ') checkpoints," \
	"$(git rev-list --merges refs/cs/heads/main | wc -l | tr -d ' ') merges"
for a in alpha beta gamma
do
	git cs fsck main..agent-$a >/dev/null
	messages=$(git log --no-merges --format=%an refs/cs/heads/main | awk -v author="$a" '$0 == author { n++ } END { print n+0 }')
	learnings=$(git log --no-merges --format=%s --author="^$a" refs/cs/heads/main | awk '/^learning: / { n++ } END { print n+0 }')
	commits=$(git rev-list --count main..agent-$a)
	test "$messages" -ge 3 && test "$learnings" -ge 1 && test "$commits" -ge 1
	echo "$a: $messages messages on main, $learnings learnings, $commits code commits, fsck clean"
done
# Delay until each agent's cursor first covered a teammate's learning.
coverage=read-coverage
: >"$coverage"
for reader in alpha beta gamma
do
	git log -g --format='%H %gd' --date=unix refs/cs/seen/$reader 2>/dev/null |
	sed 's/ .*@{\(.*\)}$/ \1/' | sort -k2n >reads
	git log --format='%H %ct %an %s' refs/cs/heads/main | grep ' learning: ' |
	while read -r note made author rest
	do
		test $author != $reader || continue
		while read -r seen at
		do
			if git merge-base --is-ancestor $note $seen
			then
				echo "$reader cursor covered $author's learning $((at - made))s after it was recorded" >>"$coverage"
				break
			fi
		done <reads
	done
done
test "$(wc -l <"$coverage")" -ge 6
cat "$coverage"
rm -f "$coverage"
rm -f reads
for a in alpha beta gamma
do
	git merge -q --no-commit --no-ff agent-$a || exit 1
	git cs commit-code --context main -- -q -m "Merge agent-$a" || exit 1
done
test_output=$(python3 -m unittest discover -s tests 2>&1) || { echo "$test_output"; exit 1; }
echo "$test_output" | grep -Eq '^Ran [1-9][0-9]* tests? in '
echo "tests: $(echo "$test_output" | tail -1)"
git cs fsck $base..main >/dev/null
echo "fsck of all agent and merge commits: clean"
git init -q --bare -b main ../team-hub.git && git cs push ../team-hub.git main agent-alpha agent-beta agent-gamma >/dev/null 2>&1 &&
git clone -q ../team-hub.git ../team-rx && cd ../team-rx && git cs fetch origin >/dev/null 2>&1 || exit 1
n=0 t=0
for c in $(git rev-list $base..origin/main)
do
	t=$((t + 1))
	git cs show "$(git cs links --code $c)" >/dev/null 2>&1 && n=$((n + 1))
done
test "$t" -gt 0
test "$n" -eq "$t"
test_output=$(python3 -m unittest discover -s tests 2>&1) || { echo "$test_output"; exit 1; }
echo "$test_output" | grep -Eq '^Ran [1-9][0-9]* tests? in '
echo "fresh clone: $n/$t links resolve, tests $(echo "$test_output" | tail -1)"
