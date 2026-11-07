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

The answer is one of `dotsteward skills track <name> --all`, `--here` (this machine
only) or `--never` (this machine, asked no more). `--own` tracks your own copy of it
without an upstream. Never tracked: `~/.claude/skills/synced/`, `dotsteward-*`,
`~/.codex/skills/.system`, plugin and project skills.

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

## The capture

Ten minutes after the last change of a skill (`[skills] capture_delay_seconds`), or when
the session that wrote it ends, whichever comes first, `dotsteward skills capture` publishes
it. It works
in a worktree of its own below the state root, so a dirty checkout is no obstacle and the
checkout never moves; `agents install` knows a checkout that stayed behind, and `dotsteward
upgrade` moves it. A file deleted here leaves the repository. An existing lock entry changes
its digests only.

A commit passes `static` (with the privacy scan and its denylist) and `pins check`, run by
the CLI the tree pins, and goes out without force. When another machine came first, the copy
is replayed on the new tip. The same skill changed on two machines is a conflict: no commit,
your files stay, and `dotsteward skills diff <name> --json` names the three trees; `dotsteward
skills resolve <name> --ours` publishes your copy, `--theirs` backs it up and installs the
one of the repository.

| What keeps a skill back | What happens | Exit |
| --- | --- | --- |
| a privacy finding | no commit; the rule and the place in `last-capture.json`, never the text | 4 |
| a red check | no commit, `blocked`; a new tip of the remote gets a new try, by itself within hours | 1 |
| a refusal of the remote | no push, `blocked`; `dotsteward skills status` shows what the remote said, and `dotsteward skills retry <name>` tries again once the cause is gone | 1 |
| a link out of the tree (`unsafe-link`), above the size limit (`too-large`), no `name` in the frontmatter (`skill-invalid`) | no commit, `blocked` | 1 |
| a conflict | no commit | 3 |
| no network | the name waits in `pending.json`, no commit piles up, the next hook tries again | 6 |

The skill keeps working here. You hear of it once: in the next session somebody attends,
through `notify-send` where there is one, and in `dotsteward skills status`; the same content
is neither tried nor told again. Whatever keeps a skill waiting for more than a day (no
network, a launcher that cannot run, a capture that failed) is said in the session too, so a
dead credential does not stay silent.

`dotsteward skills forget <name>` takes a skill from all machines. `dotsteward skills restore
<name>` brings one you deleted back from the repository. All of this lives in
`<state>/skills/`, which never enters the repository.

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
| `SessionEnd` | captures what this session wrote now, detached; everything else keeps its delay |

A hook cannot fail or delay an agent: it always exits 0, also with a broken CLI or a
read-only home, and it ends at once with `DOTSTEWARD_HOOKS_OFF=1`. In a subagent it only
records that a file tool wrote the skill. Without a change it starts no process. A question
needs somebody to answer it: it reaches the agent only in a session somebody attends, at
most once per item in 24 hours, with at most 10 names and never any content of a skill.
Otherwise the item waits for the next session or for `dotsteward skills status`.

Codex runs no hook of the user's file before you trust it with `/hooks`, once per
machine; `dotsteward skills hooks check` says when that waits. `skills hooks remove` takes
the entries out until the next rebuild; `tracking = false` is the lasting switch.
