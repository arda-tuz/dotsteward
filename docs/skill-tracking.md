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
| a clean clone with a remote: the directory is one, or a link from the skill root resolves into one (the skill a directory of it) | a question |
| a file tool of an agent wrote its `SKILL.md`, or `claude plugin init` made it | tracked, no question |
| anything else: a tree no file tool touched | a question |

The answer is one of `dotsteward skills track <name> --all`, `--here` (this machine
only), `--never` (this machine, asked no more) or `--later` (nothing is declined or
published; no session asks about it again, and `skills status` keeps listing it). Only
`--never` declines, and the session text tells the agent so: a "not now" is `--later`, and
no answer at all runs nothing, so the question comes back after 24 hours. Every answer stays on the pending item as `answered` (which one,
and when), and `skills status` shows it for a declined skill. `--all` or `--here` given
later takes a `--never` back. `--own` tracks your own copy of it without an upstream.

A downloaded skill pins its upstream. From a clone that is the remote `origin` (without any
credentials it may carry), the commit HEAD and the directory of the skill within the clone
(`source`, `revision` and `source_path` of its lock entry). The clone counts only when another
machine could fetch the same tree: a remote, a commit that holds the directory, and no change
of the directory that the commit does not have (an untracked file counts). Otherwise the skill
is unknown, and `skills status` and the refusal of `--all` say why; a directory with a `.git`
of its own stays so even after a file tool wrote into it. Only the directory and the target
of a link are looked at, never the directories above a real one. The vendored copy is the
directory of the upstream as it is; when the upstream keeps its license above that directory,
as most repositories do, the nearest `LICENSE*` above it at the pinned commit goes to
`agent/skill-licenses/<directory>/`, where the license rule of `static` finds it. The answer looks
at the clone again, so a clone cleaned up meanwhile is fine, and `skills reconcile --full`
does the same for every unknown question. A clone that pulls by itself afterwards is newer
than the pin, not drift: `agents install` leaves it alone and `agents check` passes with a
note, as long as it holds no change of its own and its HEAD descends from the pinned commit;
the update of pins moves the pin. Never tracked: `~/.claude/skills/synced/`, `dotsteward-*`,
`~/.codex/skills/.system`, plugin and project skills.

## Plugins of Claude Code

A plugin is tracked the same way, under its own name in `dotsteward skills status`.

| What it is | What happens |
| --- | --- |
| a directory in `~/.claude/skills` with `.claude-plugin/plugin.json` (`claude plugin init`; Claude Code loads it as `<name>@skills-dir`) | tracked, no question: the copy goes to `agent/plugins/<directory>/` with an `own_plugins` entry of the lock, and `agents install` puts it into `~/.claude/skills` of the other machines as a real directory, under the rules of the next section |
| with the codex component, a directory in `${CODEX_HOME:-~/.codex}/plugins` with `.codex-plugin/plugin.json` or `plugin.json` (the place of a personal plugin in the Codex documentation) | the same, with `agents = ["codex"]`; `agents install` offers it to Codex through a marketplace of dotsteward, `dotsteward-own` in `${XDG_DATA_HOME:-~/.local/share}/dotsteward/codex-marketplace` (a link to the copy; your personal marketplace `~/.agents/plugins/marketplace.json` is never touched), and runs `codex plugin add`, again after an incoming change, because Codex runs the copy in its cache; a plugin a marketplace of yours installed from that copy is left to it |
| either with a `.git` directory | a question; `--own` tracks your own copy of it |
| a plugin of a GitHub marketplace, installed at user scope (`installed_plugins.json` and `known_marketplaces.json` of `${CLAUDE_CONFIG_DIR:-~/.claude}/plugins`) | a question, by its spec `NAME@MARKETPLACE` |

For a plugin of a marketplace, `--all` adds a `[[components.claude-code.options.plugins]]`
table with `spec` and `marketplace` to `workstation.toml`, `--here` with `machines` too, and
the plugins hook of the claude-code component installs it on the other machines. The
manifest mirror carries the component options, so the same commit carries what `dotsteward
generate` makes of the new tree (its evaluation also runs every check of the component on the
table) and goes out on the maintain ref; a failed evaluation publishes nothing
(`generate-failed`). This needs Nix, so only `skills track` and `skills retry` carry such an
answer, never a hook or a capture in the background; `--never`
puts the spec into `declined.plugins` of the host file. `--own` does not apply. Take the
table out of `workstation.toml` again (by hand, or on another machine) and the plugin is not
tracked any more: once the checkout has that change, a machine where it is installed asks
about it again, once, with the reason `untracked`; nothing tracks it by itself. The
marketplace keeps its plugins up to date by itself: an update is no change to publish, and an
update of a plugin you did not track never tracks it. No question comes for a plugin at
project scope, of a marketplace that is not a GitHub one, of Claude Code itself (`synced`,
`builtin`), or while the instance does not enable claude-code. Finding them reads those two
files, only after they changed, and starts no process. Plugins of Codex marketplaces are not
tracked yet. A name is one own plugin: an own plugin of the other agent with the name of a tracked one
is `name-taken` (reason `other-agent`), said in the session and in `skills status`, and
never published; renamed, it is a plugin of its own. An own plugin that is for other machines only
(`machines`) holds its name here too: a directory of that name is `name-taken`, like a
skill.

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

A copy of a skill that still carries its `name` never lands on that skill: it waits as
`name-taken` until you rename it, and then lands as a skill of its own.

Two different local copies of one skill (a leftover in another root, a directory named
after the skill beside its own) stop as well: nothing says which one is the skill. When one
is gone, `dotsteward skills retry <name>` goes on.

A copy on the remote that this machine has not seen is overwritten only by `dotsteward skills
resolve <name> --ours`: an answer to "track it?" ends in a conflict then. A file the ignore
rules of the skill on the remote leave out never goes there, not after `--ours` either
(`ignored-file`).

The name is the identity of a skill. `--never` and `forget` are recorded by name in the host
file of this machine, so they hold after a rename of the directory and after its state is
gone; a skill with a new name in its frontmatter is a new skill, and is tracked as one.

`dotsteward skills forget <name>` takes a skill from all machines. `dotsteward skills restore
<name>` brings one you deleted back from the repository. What `--never` and `forget` keep out
stays out when an agent edits the copy later; only another answer takes it back. Once the
copy is gone too, `dotsteward skills forget --clear <name>` is that answer: the name leaves the
host file and `skills status`, and a new skill of that name is a new skill. A copy
linked to a place outside the skill roots is not refreshed: it stays a `conflict` until you
answer, so it never replaces what another machine published. A refresh and `resolve --theirs`
leave what the normal form leaves out (ignored files, the `.git` of a clone) where it is. All
of this lives in `<state>/skills/`, which never enters the repository.

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
