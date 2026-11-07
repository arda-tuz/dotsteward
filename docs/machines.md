# Machines

An instance can describe more than one machine. Nothing here is required: an
instance that names no machine behaves as if none of this existed.

## The name of a machine

`dotsteward host init` gives this machine its name, which is yours to choose. The
name matches `^[a-z0-9][a-z0-9-]{0,31}$`. `./bootstrap.sh` asks for it first on a
terminal. Without a terminal it takes `DOTSTEWARD_MACHINE`, or with
`DOTSTEWARD_ASSUME_YES=1` the cleaned host name; an instance whose `hosts/` names no
machine goes on without a name then. Only `<state>/machine.json` is written, so the
checkout stays clean and the bootstrap needs no git identity.

`dotsteward host publish` brings `hosts/<name>.toml` to the remote without touching
the checkout. The bootstrap tries it at its end when the instance names machines
already, in `hosts/` or as `[hosts] producer`; the first machine of an older instance
is registered with the command, once checks of the instance that list the files of
its tree allow it. Without a network or a login it says so and the next `host publish`
picks it up. A checkout that is behind the
remote after that passes `dotsteward e2e` with a note; `git pull --ff-only` moves it.
The file is scanned first with the policy of the instance, as `dotsteward static`
scans everything there: a finding stops the publish.

## The host file

`hosts/<name>.toml` says what the other machines may know about this one, and only
that machine writes it ([schema](../schema/host.schema.json)):

```toml
schema_version = 1
system = "x86_64-linux"
profile = "workstation"
platform = "ubuntu-24.04"
tags = ["laptop"]
declined = { components = [], skills = ["example-skill"], plugins = ["example@market"] }
```

A reinstall under the same name reads it again (`dotsteward host init --name NAME
--reuse`, the answer on a terminal, or `DOTSTEWARD_MACHINE_REUSE=1` for
`./bootstrap.sh`), so what the machine declined stays declined and what is scoped to it
comes back.

## What applies to a machine

An entry with `machines = ["<name>", ...]` is for those machines only. That goes for
the entries of the skills lock, for `own_plugins` there, for
`[[components.<agent>.options.plugins]]` and for `[components.<name>]`, which also takes
`tags = ["<tag>", ...]`: a machine with one of them gets the component. Other machines
never get such an entry and are never asked; a machine without a name is another machine.
A reinstall under the same name brings it back, without a question. `hosts/<name>.toml`
declines entries for one machine.

```sh
dotsteward skills effective --json
```

prints the one answer the commands act on: the name, the profile, the tags, and
what this machine leaves out with one word for each. `dotsteward agents` neither
installs nor misses what is left out, and neither do the checks of the agents.
`name_taken` lists the skills the lock keeps for other machines while this machine
has one of that name.

`dotsteward host check`, which `dotsteward static` runs, reports the problems of the tree: a host file that is not
valid, and `machines` lists that are empty or name a machine without a host file.

## What Nix knows about a machine

The machine layer hands Nix tags and nothing else, so the same system, profile and tag set
always give the same evaluation. The tags of a machine are the `tags` of its file,
`machine:<name>`, and `no:<component>` for each entry of `declined.components`.
`dotsteward rebuild` adds `no:<component>` for a new component this machine has not
answered about, and writes `tags` into `profile.nix` only when there are any. The
generated host flake passes `mkHome` only the arguments it takes, so a framework pin older
than the tags keeps working. Nix reads `system`, `profile`, `tags` and
`declined.components` of a host file, as intent; it reads no answer and no state of a
machine.

A component that is left out on a machine is not active there: `helpers.isActive` decides,
in every module. The manifest does not change with it: `machines`, `tags`, `requires` and its
`managed_links` are data in its component entries, there is one manifest per system, and the
commands of the CLI leave the component out by `skills effective`.
`checks.<system>.manifest-consistent` holds every machine to that.

Nothing of a component that is not active is expected on the machine, whatever left it out
(`machines`, `tags`, an answer, a profile): one predicate, `methods_components`, says what is
active for `agents install`, for the managed links and the settings targets of `e2e`. A settings
entry of such a component waits in the buffer: the targets file of a generation holds every
target with `active`, so it is no unknown target; `rollback` still reads every link.

`hostConfigurations.<name>` is the configuration of a machine, under the check identity.
`checks.<system>.hosts-eval` evaluates each distinct tag set of the machines of that system
without building it, so an assertion of any machine stops the gate of every machine, and says
which machine it is about. `gate` builds and probes the configuration of the machine it runs on
when the tree has its file on the primary system (`checks.<system>.home` otherwise, and under
a framework pin older than this output), and records `host` and `tags_sha256` in
`generation.json`. `rebuild` reuses that generation only for the tags it would use itself,
so what differs only by an answer of this machine is proved by its own build and E2E.

## What a component needs

A component says what it needs with `requires`. That is a statement about one machine at a
time, which the CLI of that machine reads from the manifest; Nix never fails for it, so no
machine's gate depends on another machine's answer. What a component this machine runs needs
comes with the tree, without a question, and the report names both. When both are new, the
questions say so, and installing the one takes the other along. A component that needs what
this machine leaves out is left out too (`requires` in `skills effective`, a `no:` tag on
this machine), and the person here is told, in the output and in `review.json`.

## What other machines changed

The repository always moves forward; what lands on a machine depends on the answer.
`dotsteward incoming` brings a clean checkout forward and asks, one item at a time and with
the machine that made the change:

| Change | Install | Ask later | Never on this machine |
| --- | --- | --- | --- |
| New skill, own or third party | copied here | not copied | `declined.skills` |
| Own skill changed, local copy unchanged | backup, new copy | the old copy stays | `declined.skills`, the copy stays, tracking ends |
| Own skill removed, or this machine left its `machines` | backup, removed here | the copy stays | `declined.skills`, the copy stays, not asked again |
| New plugin | installed | not installed | `declined.plugins` |
| New component | active from the next `upgrade` or rebuild; nothing expects it before | a `no:` tag on this machine | `declined.components` |
| Third party skill, a copy here has that name | backup, the skill of the lock | the copy stays | `declined.skills`, the copy stays |

Everything else needs no question: pins and the rest of the intent arrive as a whole tree
with the next rebuild. A change here and there is a conflict, which `dotsteward skills
resolve` answers. What is scoped to other machines is never asked about.

Without a terminal every item is ask later: `review.json` holds it under the code
`incoming`, the exit status is 3, and everything else goes on. `dotsteward incoming list`,
`show ID` and `answer ID --install|--never` are the same conversation for an agent
(`skills/dotsteward-update/references/incoming.md`); to ask later, do nothing.

Nothing keeps a cursor or a queue: every run compares the tree with what the machine
holds. Ask later therefore stores nothing. Never goes to `hosts/<name>.toml`, because it is
the intent of the machine and a reinstall under the same name finds it; without a network
it holds through `<state>/machine/never.json` and a later `incoming` or `upgrade` publishes it. A `no:` tag in a host
file must leave that machine evaluating, or an assertion of it would stop the gates of the others,
so Never on a component evaluates the machine first and refuses when Nix says no.

The change is this machine's own, and no question, when a commit that is not published
yet touches its path or the last commit that did says `Dotsteward-Machine: <this
machine>`; every commit the framework makes for an instance says that. `dotsteward txn publish` puts that line
on every commit it sends from a named machine, also on a plain `git commit`, with the same tree,
author and dates; a commit with no such line comes from an unknown machine. `<state>/machine/known.json`
holds the plugins and components the machine knows; a skill is answered by its copy and
`base.json`, so a skill that left and comes back asks again. A machine without the file (a fresh
install, or one set up before this release) takes what is for it now as known, on its first
`agents install`, and nothing is asked. A third party skill whose copy here never was a pin of the
lock is the user's own under that name: it stays and is a question.

## The trace line

A commit that the framework makes in an instance for a machine ends with the trace line
`Dotsteward-Machine: <name>`: the commits of `host`, of a skill capture and of the writer of
`upgrade`. It says which machine made a change, for example where a skill came from. A machine
without a name commits without it. The rule that framework commits carry no trailer is about the
framework repository, not about an instance.

## The producer

`[hosts] producer` names the machine that moves the values that come from upstream:
`flake.lock`, the pins and the third-party skills. `dotsteward init --machine NAME`
or `dotsteward host producer NAME` writes it.

## A tree newer than the CLI

A commit may use a new key only in a tree whose `flake.lock` pins a framework that
knows it. A machine whose CLI is older than its tree stops at the key, and the
message names the way out, the CLI the tree pins: `.dotsteward/cli.sh <command>`.
