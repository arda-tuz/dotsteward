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

An entry with `machines = ["<name>", ...]` is for those machines only. In this
release that goes for the entries of the skills lock and for `own_plugins` there.
Other machines never get such an entry and are never asked; a machine without a name
is another machine. `hosts/<name>.toml` declines entries for one machine.

```sh
dotsteward skills effective --json
```

prints the one answer the commands act on: the name, the profile, the tags, and
what this machine leaves out with one word for each. `dotsteward agents` neither
installs nor misses what is left out, and neither do the checks of the agents.
`name_taken` lists the skills the lock keeps for other machines while this machine
has one of that name.

`machines` on `[[components.<agent>.options.plugins]]` is read by the plugin hooks.
The catalog modules refuse the key until the release that accepts it.

`dotsteward host check` reports the problems of the tree: a host file that is not
valid, and `machines` lists that are empty or name a machine without a host file.

## The producer

`[hosts] producer` names the machine that moves the values that come from upstream:
`flake.lock`, the pins and the third-party skills. `dotsteward init --machine NAME`
or `dotsteward host producer NAME` writes it.

## A tree newer than the CLI

A commit may use a new key only in a tree whose `flake.lock` pins a framework that
knows it. A machine whose CLI is older than its tree stops at the key, and the
message names the way out, the CLI the tree pins: `.dotsteward/cli.sh <command>`.
