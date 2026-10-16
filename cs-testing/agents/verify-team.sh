#!/bin/bash
# Usage: verify-team.sh <sandbox>
# After the agents finish: check the shared context, merge their code with linked merge
# commits, run the tests, and prove a fresh clone resolves every link.
SB=${1:?usage: verify-team.sh <sandbox>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PATH="${CS_GIT_BIN:-$ROOT/bin-wrappers}:$PATH"
cd "$SB/team" && base=$(git rev-parse HEAD)
echo "team context: $(git cs show main | jq '.active | length') chunks," \
	"$(git rev-list refs/cs/heads/main | wc -l | tr -d ' ') checkpoints," \
	"$(git rev-list --merges refs/cs/heads/main | wc -l | tr -d ' ') merges"
for a in alpha beta gamma
do
	echo "$a: $(git cs show main --messages | grep -c " $a: ") messages on main," \
		"$(git rev-list --count main..agent-$a) code commits," \
		"fsck $(git cs fsck main..agent-$a >/dev/null 2>&1 && echo clean || echo FAILED)"
done
for a in alpha beta gamma
do
	git merge -q --no-commit --no-ff agent-$a || exit 1
	git cs commit-code --context main -- -q -m "Merge agent-$a" || exit 1
done
echo "tests: $(python3 -m unittest discover -s tests 2>&1 | tail -1)"
echo "fsck of all agent and merge commits: $(git cs fsck $base..main >/dev/null 2>&1 && echo clean || echo FAILED)"
git init -q --bare -b main ../team-hub.git && git cs push ../team-hub.git main agent-alpha agent-beta agent-gamma >/dev/null 2>&1 &&
git clone -q ../team-hub.git ../team-rx && cd ../team-rx && git cs fetch origin >/dev/null 2>&1 || exit 1
n=0 t=0
for c in $(git rev-list $base..origin/main)
do
	t=$((t + 1))
	git cs show "$(git cs links --code $c)" >/dev/null 2>&1 && n=$((n + 1))
done
echo "fresh clone: $n/$t links resolve, tests $(python3 -m unittest discover -s tests 2>&1 | tail -1)"
