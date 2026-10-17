#!/bin/bash
# Usage: setup-team.sh <sandbox>
# Create a shared team repository with a seeded team context and one worktree per agent.
SB=${1:?usage: setup-team.sh <sandbox>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PATH="${CS_GIT_BIN:-$ROOT/bin-wrappers}:$PATH"
mkdir -p "$SB" && cd "$SB" && rm -rf team team-hub.git team-rx wt-alpha wt-beta wt-gamma scratch-*.json
git init -q -b main team && cd team && mkdir textstats tests
printf '"""textstats: small text statistics helpers."""\n\n\ndef word_count(s):\n    return len(s.split())\n' >textstats/__init__.py
printf '# textstats\n- alpha: textstats/tokens.py tokenize(s)\n- beta: textstats/top.py top_words(s, n)\n- gamma: tests/test_textstats.py\n' >README.md
git add . && git commit -q -m "textstats skeleton"
git cs init
git cs commit main --from coordinator -m "Team goal: textstats package with tokenize, top_words and tests. Python 3 stdlib only." >/dev/null
git cs commit main --from coordinator -m "Share every decision other agents depend on (names, signatures, rules) as a learning on the team context branch main, with --path for the files it concerns." >/dev/null
for n in alpha beta gamma; do git worktree add -q -b agent-$n ../wt-$n main; done
echo "team ready in $SB (code base $(git rev-parse --short HEAD))"
