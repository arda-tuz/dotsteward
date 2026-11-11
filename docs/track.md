# Tracking: add, remove and status

Software outside the framework's own skills and plugins is tracked only when the person says so.
They tell the agent "track this", and the agent runs `dotsteward add`; "stop tracking that" is
`dotsteward remove`. Each is one maintain transaction ([apply.md](apply.md)): it opens with
`maintain begin`, writes the intent, and finishes with the one `dotsteward apply`, whose gate,
commit with the trace line, activation, E2E and publish run as they always do. `dotsteward status`
is the overview that goes with them: what is tracked, what applies here, what waits.

```sh
dotsteward add example-viewer --activate --publish           # a catalog component
dotsteward add example-notes --apt example-notes --publish   # plain APT packages
dotsteward add example-grep --nix ripgrep --command rg       # a nixpkgs package
dotsteward remove example-viewer --publish                   # the software stays installed
dotsteward status                                            # read-only, offline
```

## add

`dotsteward add NAME [--apt PACKAGE]... [--nix ATTRIBUTE] [--command COMMAND]... [--method METHOD]
[--profiles PROFILE,...] [--machines MACHINE,... | --here] [--tags TAG,...] [--updater UPDATER]
[--with-changes] [-m SUBJECT] [--activate | --no-activate] [--publish | --no-publish]
[--profile PROFILE] [--json]`

The channel of NAME decides what it writes:

| NAME | What add writes |
| --- | --- |
| a catalog component | `[components.NAME]` with `enable = true` |
| a component of the instance, `components/NAME/default.nix` (written by the maintain skill, committed or not) | the same table; the files of the component go into the same commit |
| `--apt PACKAGE`: plain APT packages that a source of this machine offers or that are installed (read from the local lists with `apt-cache policy`) | `components/NAME/default.nix`, a Linux `deb` component with `install.deb.pin = null` and those packages, which plain `apt upgrade` keeps up to date, and the table |
| `--nix ATTRIBUTE`: a nixpkgs package | `components/NAME/default.nix`, a `nix` component with `pkgs.ATTRIBUTE` in the Home Manager profile, and the table |
| anything else | nothing: exit 3 with `channel-unknown` |

`--command` names a command the package provides, which the component's command check then
expects. The scope options write `machines` (`--here`: this machine's name), `tags`, `profiles`,
`method` and `updater` into the table ([workstation-toml.md](workstation-toml.md)); a table that is
there already keeps its other keys and gets `enable = true`. The file keeps its comments and
layout: a new table goes after the last `[components]` table, never between a comment and the
header that comment is about, and a new key goes at the end of its table. A value the schema refuses is a usage error, before anything runs.

An official binary, a vendor APT repository, a release download or a Python application needs
pins, hashes, a signing key or other research: that is no guess of a command. `add` writes nothing
and answers `channel-unknown`; the `dotsteward-maintain` skill researches the channel and writes
`components/NAME/default.nix` (with its pins: a new component may add its first pins on any machine,
[machines.md](machines.md#who-writes-what)), then the same `dotsteward add NAME` finishes. When
the component needs changes outside its directory too (its pins in `versions.lock.json`, a flake
input), `--with-changes` says they belong to this transaction, which then commits them with it. A file
that is in the way (`components/NAME/default.nix` with other content than `--apt` or `--nix` would
write) is a refusal.

A catalog component that needs pins the lock does not have yet (an official binary, a release
download) stops at the pins check of the gate, which names them; nothing is committed. The maintain
skill adds those first pins, and `dotsteward add NAME --with-changes` finishes.

The subject is `feat: track NAME` unless `-m` gives another conventional one. The options of
`apply` pass through unchanged; without them `[maintain]` of `workstation.toml` decides, as for
`apply`. On an adopt-mode profile `--activate` installs a new `deb` component before the rebuild,
through sudo on a terminal, else with `install-required` (exit 3), exactly as `apply` does.

## remove

`dotsteward remove NAME [--uninstall] [--with-changes] [-m SUBJECT] [--activate | --no-activate] [--publish |
--no-publish] [--profile PROFILE] [--json]` removes `[components.NAME]`, NAME from
`[components] order` and, for a component of the instance, the directory `components/NAME`, under
the subject `feat: stop tracking NAME`. The comment right above the table goes with it when it
names the component; one that does not may be about more tables, so it stays as a paragraph of its
own and remove says so. The directory goes only with a table that was there: one that was never tracked is someone's
work in progress. A component that another enabled component requires stays
(exit 1, naming it); remove that one first. A name that is not tracked is nothing to do.

Stopping to track never uninstalls what the person keeps:

| Method | Without `--uninstall` | With `--uninstall`, once the commit landed |
| --- | --- | --- |
| `deb` | the packages stay installed; plain `apt upgrade` still updates them, nothing else follows them | `sudo apt-get remove` of the packages no other component names, on a terminal; without one `uninstall-required` with the command (exit 3), and the same `remove --uninstall` later runs it |
| `official-binary` | the binary stays | the binary and its companions are deleted |
| `pypi` | the virtual environment stays | the environment and its links are deleted |
| `nix` | it leaves the Home Manager profile at the next activation, as every change of the intent does: a generation holds what the intent names | the same |
| `system`, `app-archive`, `external` | stays | stays: remove it by hand |

What `--uninstall` removes is worked out from the manifest mirror before the component goes, and
kept in `<state>/track/uninstall-NAME.json` until it is done, so a run that waits for a sudo step or
the network finishes later.

## What both do around the change

Both hold the instance lock; `maintain begin` and `apply` run nested in it, through the dispatcher.
Each commits only its own change: the paths of the component (`workstation.toml` where only the
table of NAME and its entry of the order differ, `components/NAME/`, the mirrors under
`.dotsteward/`). Another change of the checkout or a commit the remote lacks is the question of
`maintain begin` (`checkout-dirty`, `unpublished-commits`): nothing is written, exit 3. What an
earlier run for the same component left, a red gate, a commit whose push waited for the network, is
its own, and the same command finishes it. `--with-changes` answers `checkout-dirty` for the
uncommitted changes the person agreed belong to it; commits the remote lacks stay a question. The questions `nonconventional-commits` and
`adaptive-route` stop it the same way; `settings-local` is only a note.

`--json` prints one document: `command`, `component`, `channel` (`add`), `change` (`added`,
`enabled`, `changed`, `removed`, `unchanged`, or null when nothing was looked at), `ask`, `notes`,
`apply` (the report of the `apply` it ran, else null), `uninstall` (`remove`: `status`, `run`,
`removed`) and `exit_code`. Each run leaves a report in `<state>/runs/add/` or `runs/remove/`, and
its questions in `review.json`. After a green publish, `apply` records the state of this machine on its
state branch, so the orphans of `status` are those of other machines that did not record since.

## status

`dotsteward status [--json]` is one read-only overview. It reads the checkout and its refs as the
last fetch left them, the records of the state root and the manifest mirror; it fetches nothing,
starts no other command, takes no lock and writes nothing, so it answers at once, without a network
and while another command runs.

| Part | What it says |
| --- | --- |
| `machine` | the name of this machine (null before `host init`), the platform, profile, tags, framework release and the producer |
| `checkout` | the branch, `HEAD`, the remote tip the last fetch saw and when, commits ahead and behind, changed paths |
| `activation` | whether the active generation is the checkout, and how E2E went on it (`pass`, `fail`, null) |
| `components` | every enabled component: its method, updater, version constraint, holds of this machine, whether it applies here and why not (`machines`, `tags`, `profile`, `platform`, `declined`, `incoming`, `requires`), and whether it is installed where that is cheap to read (`deb` by `dpkg-query`, `official-binary` and `pypi` by their files) |
| `holds`, `updates` | the holds of `upgrade` on this machine, and what its last research found newer than the pins |
| `incoming` | what other machines brought that waits for an answer here ([machines.md](machines.md)) |
| `skills`, `plugins` | the tracked skills (own or third party) and plugins, which apply here, whether skill tracking is on, which captures wait |
| `state`, `orphans` | the last record of the state branch of this machine and whether it waits for its push; the components of that record the intent no longer has |
| `review` | the items of `review.json` |

What the machine has that nobody tracks is no part of it. The local settings are `dotsteward
settings status`.
