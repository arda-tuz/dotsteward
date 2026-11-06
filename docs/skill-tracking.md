# Skill tracking

A skill you make in Claude Code or Codex reaches your other machines without a
question. A skill you download gets a question, inside the session. No daemon runs
for this and no model reads anything: the hooks of the agents and a comparison of
files do all of it. `[skills] tracking` in `workstation.toml` switches it on;
`dotsteward init` writes `true`, and an instance that does not name the key behaves
as it always did.

An own skill is one whose revision in `agent/skills.lock.json` is a repo-owned
sentinel (`same-as-instance-checkout` or `[compat] repo_owned_revision`).

## What happens to a new skill

| Where it comes from | What happens |
| --- | --- |
| a record in `~/.agents/.skill-lock.json` (`npx skills`) | a question |
| a `.git` directory | a question |
| a file tool of an agent wrote its `SKILL.md`, or `claude plugin init` made it | tracked, no question |
| anything else: a tree no file tool touched | a question |

Never tracked: `~/.claude/skills/synced/`, `dotsteward-*`, `~/.codex/skills/.system`,
plugin and project skills.

## Your copy is never overwritten

`rebuild` and `agents install` compare three digests for an own skill: the local copy
(its normal form, see below), the lock of the checkout and what this machine last had
in sync (`<state>/skills/base.json`).

| State | Meaning | `agents install` | `agents check` |
| --- | --- | --- | --- |
| `in-sync` | the copy equals the lock | records it | passes |
| `behind` | the checkout has not caught up with a capture | leaves it | passes, note |
| `pending-capture` | you changed the copy | leaves it | passes, note |
| `incoming` | the repository moved, your copy did not | backup, then refresh | passes, note |
| `conflict` | both changed, or the first look finds a difference | leaves it | passes, note |
| `deleted` | you deleted the copy | does not install it again | passes, note |
| `missing` | a skill of the lock this machine never had | installs it | `skill-missing` |

Third-party skills keep their drift check and their refresh. `dotsteward skills status`
shows all of this. The normal form is what a copy carries: what git would list, with the
`.gitignore` files of the skill and of the instance, without `.git`, `__pycache__`,
`__pypackages__`, `*.pyc` and `metadata.json`; a link inside the tree counts as its
target. `skills status` names what ignore rules leave out, so that a line such as
`state/` does not carry a skill incomplete without a word.

## The hooks

`skills hooks install` puts one entry per event into the configuration of each enabled
agent, next to whatever is there: `settings.json` of Claude Code, `hooks.json` of Codex.
A rebuild does this through the `skill-hooks` hook of the two catalog components, and
takes the entries out again when `[skills] tracking` is off.

| Event | What it does |
| --- | --- |
| `SessionStart` | compares; says what waits, if somebody attends the session |
| `PostToolUse` | a file tool wrote below a skill root: evidence, and the debounce |
| `Stop` | compares; Claude Code only: one block per session with what waits |
| `SessionEnd` | captures now, detached, when something waits |

A hook cannot fail or delay an agent: it always exits 0, also with a broken CLI or a
read-only home, and it ends at once with `DOTSTEWARD_HOOKS_OFF=1`. In a subagent it only
records that a file tool wrote the skill. Without a change it starts no process. A question
needs somebody to answer it: it reaches the agent only in a session somebody attends, at
most once per item in 24 hours, with at most 10 names and never any content of a skill.
Otherwise the item waits for the next session or for `dotsteward skills status`.

Codex runs no hook of the user's file before you trust it with `/hooks`, once per
machine; `dotsteward skills hooks check` says when that waits. `skills hooks remove` takes
the entries out until the next rebuild; `tracking = false` is the lasting switch.
