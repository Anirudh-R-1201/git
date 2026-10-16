# Agent prompt template

Give each of three parallel agents this prompt, replacing `{{NAME}}` with
`alpha`, `beta` or `gamma`, `{{SANDBOX}}` with the sandbox passed to
`setup-team.sh`, `{{REPO}}` with this checkout's root, and `{{TASK}}` with the
matching task below.

---

You are agent {{NAME}}, one of three agents (alpha, beta, gamma) working IN
PARALLEL on a tiny Python package. You share learnings ONLY through `git cs`,
a git extension that versions context in a history separate from code. Do not
read the other agents' worktrees or code branches; learn about their work only
from context messages.

Start every shell command with:

    export PATH={{REPO}}/bin-wrappers:{{REPO}}/cs-testing/agents:$PATH; cd {{SANDBOX}}/wt-{{NAME}};

Your worktree has code branch `agent-{{NAME}}` checked out. All worktrees share
one repository, so context branches are shared. The team context branch is
`main`; your context branch is `{{NAME}}`. Python 3, stdlib only.

Start every message you record with `{{NAME}}: `. Kinds: `plan`, `learning`,
`progress`, `ack`.

| To | Run |
|---|---|
| Create your context branch | `git cs branch {{NAME}} main` |
| Record a message | `git cs commit {{NAME}} -m "{{NAME}}: ..." --kind learning` |
| Publish to the team | `git cs merge main {{NAME}} --retry 10` (stderr says `Fast-forward`, `Merge checkpoint` or `Already up to date`; exit 75 means it still lost a race) |
| Pull teammates' learnings | `git cs rebase {{NAME}} main`, then `git cs context {{NAME}}` |
| Wait for teammates | `cs-wait {{NAME}} <agent>...` (rebases until each named agent has published a learning, then prints the context) |
| Commit code linked to your context | record the relevant message first, then `git add <files>; git cs commit-code --context {{NAME}} -- -m "message"` (plain `git commit` is refused: every code commit must name its context) |
| Inspect | `git cs log {{NAME}}`, `git cs links --code HEAD` |

{{TASK}}

Final report (under 170 words): the messages you published; which teammate
messages you read and how they changed your work; every `git cs` error message
(exact text); each publish's outcome and exit code; the first 6 lines of
`git cs log {{NAME}}`; your code commits and `git cs links --code HEAD`;
anything confusing about using `git cs`.

---

## Tasks

**alpha**: implement `textstats/tokens.py` with `tokenize(s) -> list[str]`.
1. Create your context branch and read the team brief.
2. As soon as you have decided the rule, before writing code, record a
   `learning` with the module path, signature, return type and rule with two
   examples, and publish it. Teammates depend on it.
3. Implement and check it, record a `progress` message, commit the code with
   `commit-code`, publish.
4. Run `cs-wait alpha beta gamma`. Adapt to anything teammates need (for example
   an export) and commit again.
5. Record an `ack` naming what you read and what you did; publish.

**beta**: implement `textstats/top.py` with
`top_words(s, n=3) -> list[tuple[str, int]]`, most frequent first, ties
alphabetical, reusing alpha's tokenizer. Alpha's code is not in your worktree:
learn its module and signature from alpha's learning.
1. Create your context branch, read the brief, record a `plan`, publish.
2. Run `cs-wait beta alpha`.
3. Implement against alpha's published contract (a temporary local stub is
   fine; never commit it). Record a `learning` with your module, signature and
   ordering rule with an example, commit with `commit-code`, publish.
4. Run `cs-wait beta alpha gamma` and adapt if needed.
5. Record an `ack`; publish.

**gamma**: write `tests/test_textstats.py` (unittest) for `word_count`, alpha's
tokenizer and beta's `top_words`, derived only from their published learnings.
1. Create your context branch, read the brief, record a `plan`, publish.
2. Record a `learning` with test conventions (path, how to run:
   `python3 -m unittest discover -s tests`, how tests import modules); publish.
3. Run `cs-wait gamma alpha beta`.
4. Write the tests (temporary stubs are fine; never commit them). Record an
   `ack` saying which learning produced which test, commit with
   `commit-code`, publish.
