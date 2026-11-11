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

The platform layer adds one more reason: a component that `platforms/<platform>.toml`
calls unavailable on the platform of this machine is left out with the reason `platform`
and the tag `no:<component>`, on a machine with a name or without one
([platforms.md](platforms.md#platform-files)).

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
`Dotsteward-Machine: <name>`: the commits of `host`, of a skill capture, of the writer of
`upgrade` and of `apply`. It says which machine made a change, for example where a skill came from. A machine
without a name commits without it. The rule that framework commits carry no trailer is about the
framework repository, not about an instance.

## The state of a machine

What a machine observes about itself lives on a branch of its own on the instance remote:
`state.json` on `state/<name>`, an orphan history that only that machine writes. Git builds
each commit from objects alone, so HEAD, the index and the work tree never change: the checkout
stays clean, and E2E, the gate and the commands of the checkout never see the branch.

`dotsteward state record` observes this machine: the platform, the running and newest kernel,
the active Home Manager generation and the result of the last E2E run on it, the enabled
components of the intent that apply here, and for a deb component the installed version of each
package it installs or follows (`track`). It holds the document to `schema/state.schema.json`,
an allowlist in which no field takes free text, so no user name, home directory, path, host
name, address or message can enter; and to the intent: no component outside it, no package its
component does not name. Then the privacy scan of the instance (its policy and its denylist)
reads it. A finding records nothing and exits 4. A record equal to the last one, apart from its
time, is no commit. `host` is the name the owner chose, `machine_key` the key of
`<state>/machine.json`.

Every push is a plain fast-forward, and the newest record is the tip. A record first takes in
what the other checkouts of this machine published, so the same state as the last record anywhere
is no new commit. When two checkouts of this machine (the same machine key) recorded apart, a
merge commit joins both histories: no record that waited is lost, and the tree of the tip is the
newer record by `recorded_at` (the remote one on a tie). Records with another machine key are
another machine with the same name: neither `record` nor `push` lands on them, and the local
branch never takes them as its own. `dotsteward host rename NEW` gives this machine a name of its
own; only the reinstall of that machine (named with `dotsteward host init --reuse`, which writes
`reused` into `<state>/machine.json`) continues its records with `dotsteward state push
--take-over`. Without a network the record waits on this machine (exit 6): the local branch ahead
of the remote one is the queue, and the next `state record` or `state push` sends it. Two records
at the same time in one checkout both land (the second one again on the new tip, exit 6 when that
fails too), and a state branch checked out in a work tree is never moved under it.
`[policy] observed_state_push = false` keeps the branch on this machine.
`dotsteward upgrade` records the state itself (`recorded_by: upgrade`) after it published and the
checkout followed, before the offer of tracked mode and once more after the extra pass, so what
it moved reaches the remote next to the shared lock ([upgrade.md](upgrade.md)). A machine that
is not the producer and holds back a shared lock that went red there has `held` in every record
until the lock moves: the producer reads it and puts the pins of what went red back.

`dotsteward state fetch` brings the branches of every machine to
`refs/remotes/origin/state/*`, and `dotsteward state show [NAME] [--json]` prints the state of
this machine (its local branch, and whether it waits) or of another (what the last fetch
brought, held to the schema).

## The observer

The owner changes system packages outside dotsteward: `sudo apt-get upgrade` in a terminal,
unattended-upgrades, a software center. The generation has a systemd user path unit,
`dotsteward-observe.path`, on `/var/lib/dpkg/status`, which dpkg writes at the end of every
run whatever program drove it; it starts `dotsteward observe` for the instance checkout. The
service also runs at login, since the user manager watches nothing while nobody is logged in.
Linux only; `dotsteward.observer.enable = false` in a module of the instance leaves the units
out. `dotsteward e2e` checks the unit files as managed links and, in `core:observer`, that the user
manager runs `dotsteward-observe.path`. Until an activation reached the user manager (no
`systemctl`, no user manager to ask, or a unit it never started) that check only warns; a path
unit that ran and stopped, or failed, is red. The service has no start limit
(`StartLimitIntervalSec=0`): an apt run writes the status file many times a second.

The observer first waits until dpkg settled, without holding any lock, so that `upgrade` is not
kept waiting meanwhile, and so also on a machine without a name, where it then does nothing: no
process holds a lock of `/var/lib/dpkg/lock-frontend`, `/var/lib/dpkg/lock`,
`/var/lib/apt/lists/lock` or `/var/cache/apt/archives/lock` (as `/proc/locks` lists them, which
reaches every program that drives dpkg, by device and inode; on btrfs the device of the
superblock of the mount, from `/proc/self/mountinfo`; a lock of the same inode on another
anonymous device counts only up to the wait limit), `/var/lib/dpkg/updates` is empty,
`dpkg --audit` is clean, and none of that nor a write of the status file was seen for
`--settle-seconds` (15). While a lock is held it waits without a limit;
after `--wait-limit` (1800) seconds of the other signs it observes nothing, and the next change
of the status file starts it again. Then it takes the instance lock without waiting; when another
command holds it, a pending mark makes the holder start the observer when it lets go. The lock
covers the comparison, the checks and the record on this machine; the push of the state branch
runs after it is let go.

It compares the installed packages with the last observation, `<state>/observe/dpkg-snapshot.json`.
The first run takes them as the baseline. When something changed, the tracked deb components
whose packages changed, or whose dependency closure (the `Pre-Depends` and `Depends` of the
installed packages, every alternative, the providers of a virtual package) holds a changed
package, and every component that was red, get their E2E checks alone (`dotsteward e2e
--component NAME`, a run that writes no record of E2E); the full set stays with `upgrade` and
`apply`. A component the active generation does not have yet is named and checked after the next
rebuild. Each such component is named with its result, and a red version gets one desktop
notification (`notify-send`). When dpkg moved during the checks (the owner started apt), the
verdict is dropped and the observer settles and checks again. A component without E2E checks is
named and stays unverified. A full `dotsteward e2e` run also records its verdict on the tracked
deb components it checked, so red clears once they are green again. When the checks give no result (exit 1), the state is
recorded but the change stays unobserved, so the next run checks it again. The state writer records
the state with `recorded_by: observe`: a checked component is `verified` or `red` while its
packages are the ones checked and `unverified` once they changed, with `version` (installed) and
`last_verified` apart; `<state>/state/checks.json` keeps the last check of each component, so a
later `state record` says the same. The observer never installs, removes, holds or downgrades a
package: what the owner installed stays installed. A record that waits for the network goes out
with the next run.

## The producer

`[hosts] producer` names the machine that moves the values that come from upstream:
`flake.lock`, the pins and the third-party skills. `dotsteward init --machine NAME`
or `dotsteward host producer NAME` writes it. `dotsteward contribute start` runs only there,
because `contribute upgrade` moves `flake.lock`.

## Who writes what

A value is either a function of the tree, which every machine computes the same way (the
digests of a skill, the `.dotsteward/` mirrors), or a function of upstream and time, which two
machines would answer differently (`flake.lock`, versions, hashes, the revisions of third-party
skills). Every machine writes the intent and its own skills; the producer alone writes the second
kind. `dotsteward gate` holds every tree to that in every scope, before its memo, and `skills
capture` its commit; a finding is a `writer-class` line and exit 1:

| Path | On a machine that is not the producer |
| --- | --- |
| `versions.lock.json`, `flake.lock` | a value the base has does not change or go; a new key (the first pin of a new component, a new node) and `generated_at` are free |
| the skill lock | its tool tables (`release_tools`, `nix_tools`, `npm_tools`, `npm_overrides`, `skills_cli`, `layout`) as above; a third-party entry keeps every field but `machines`, unless it becomes the instance's own (`skills track --own`) or goes (`skills forget`); a new entry is free |
| the files of a third-party skill | do not change while it is one |
| `packages/*/package-lock.json`, a hashed `requirements*.txt`, `bootstrap.sh`, `.dotsteward/cli.sh` | do not change if the base has them |
| `hosts/<other>.toml` | never written, on the producer either; `host rename` removes the old file of this machine, which `machine.json` names (`renamed_from`) |
| `[hosts] producer` | not removed: that would end the guard; `host producer NAME` names another producer |

The producer of the base decides, so a commit that names another producer moves no pin. `txn
publish` takes a proof of the gate only for its own base, so a gate against another base proves
nothing about the commits it pushes. Without
a name for this machine or a `[hosts] producer` nothing is guarded: one machine, as before.
`flake.nix` is not compared: a moved input reference shows in `flake.lock`, and the gate never
writes the lock.

## When two machines publish at once

Every push is a fast-forward and never forced. When the remote moved since the base, `txn
publish` exits 3 and pushes nothing. `apply` then moves its commits onto the new tip in a clone of
its own: a mirror both sides changed is taken from the tip and generated again into the top commit,
`flake.lock` is taken from the tip and `nix flake lock` adds what is missing, and any other change
of the same lines stops it with `publish-conflict` and the checkout as it was ([apply.md](apply.md)).
`upgrade` runs the writer again on the new tip instead ([upgrade.md](upgrade.md)). Both prove the
new tree with the gate, activate it, run E2E against the new base and push again, three times at
most (`publish-race`). A skill capture replays its copy onto the new tip
([skill-tracking.md](skill-tracking.md)).

## A tree newer than the CLI

A commit may use a new key only in a tree whose `flake.lock` pins a framework that
knows it. A machine whose CLI is older than its tree stops at the key, and the
message names the way out, the CLI the tree pins: `.dotsteward/cli.sh <command>`.
