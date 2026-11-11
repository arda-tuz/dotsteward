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
[--profiles PROFILE,...] [--machines MACHINE,... | --here | --also-here] [--replace-scope] [--tags TAG,...]
[--updater UPDATER] [--with-changes] [-m SUBJECT] [--activate | --no-activate] [--publish | --no-publish]
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
expects. A name or an attribute part that Nix reserves (`let`, `in`, `rec`, `if`, `then`, `else`,
`assert`, `with`, `inherit`) is a usage error. The scope options write `machines` (`--here`: this
machine's name; `--also-here`: the machines the table has and this one), `tags`, `profiles`,
`method` and `updater` into the table ([workstation-toml.md](workstation-toml.md)); a table that is
there already keeps its other keys and gets `enable = true`. An option that would drop values from
a list the table has (another machine, a tag, a profile) stops with `scope-narrowed` (exit 3), which
names them; `--replace-scope` confirms. Before anything runs, a value the schema refuses, a machine
without a host file (`hosts/<name>.toml`) and a method the component does not support (by its
manifest) are usage errors; `--apt` is read from the APT lists of this machine only when the
component is for it.

The file keeps its comments, its layout and its line endings (CRLF too): a table is its header and
its keys, so a new table goes after the keys of the last `[components]` table, before any comment
that follows, whether a blank line keeps that comment apart or not; a new key goes at the end of its
table.

After the change add says whether the component applies on this machine, and in `--json` `here`
and `reason`: not for `machines` (with the way on, `--also-here`), `tags`, `profile` or the
`platform`. This machine's answer Never for the component (`declined.components` of its host file,
or one not published yet) goes in the same transaction: the owner asked to track it.

An official binary, a vendor APT repository, a release download or a Python application needs
pins, hashes, a signing key or other research: that is no guess of a command. `add` writes nothing
and answers `channel-unknown`; the `dotsteward-maintain` skill researches the channel and writes
`components/NAME/default.nix` (with its pins: a new component may add its first pins on any machine,
[machines.md](machines.md#who-writes-what)), then the same `dotsteward add NAME` finishes. When
the component needs changes outside its directory too (its pins in `versions.lock.json`, a flake
input), `--with-changes` says they belong to this transaction, which then commits them with it and
names them (`with_changes` in `--json`). A file that is in the way (`components/NAME/default.nix`
with other content than `--apt` or `--nix` would write) is a refusal, unless an earlier add wrote it
and no commit holds it (a typo that went red): then the next add writes its own.

A catalog component that needs pins the lock does not have yet (an official binary, a release
download) stops at the pins check of the gate, which names them; nothing is committed. The maintain
skill adds those first pins, and `dotsteward add NAME --with-changes` finishes.

The subject is `feat: track NAME` unless `-m` gives another conventional one. The options of
`apply` pass through unchanged; without them `[maintain]` of `workstation.toml` decides, as for
`apply`. On an adopt-mode profile `--activate` installs a new `deb` component before the rebuild,
through sudo on a terminal, else with `install-required` (exit 3), exactly as `apply` does.

## remove

`dotsteward remove NAME [--uninstall | --keep-here] [--with-changes] [-m SUBJECT] [--activate | --no-activate] [--publish |
--no-publish] [--profile PROFILE] [--json]` removes `[components.NAME]`, NAME from
`[components] order` and, for a component of the instance, the directory `components/NAME`, under
the subject `feat: stop tracking NAME`. The comment right above the table goes with it when it
names the component; one that does not may be about more tables, so it stays as a paragraph of its
own and remove says so; a comment below the keys, or one a blank line keeps apart, is about what
follows and stays. In `components/NAME` only the files a commit holds go; an ignored file stays and
is named, and a file no commit holds (one git does not know, or one an add that did not finish only
staged) stops remove with `untracked-files` (exit 3) before anything is written. A table no commit
holds is no tracked component: remove leaves it, and the directory, as they are. A component that
another enabled component requires stays (exit 1, naming it), checked on the tree `maintain begin`
brought; remove that one first. A name that is not tracked is nothing to do. This machine's answer
Never and its holds for the component leave its host file and `<state>/holds.json`; pins of the
component stay in `versions.lock.json` (only the producer moves pins) and are named.

A `nix` component would leave the Home Manager profile of every machine it is for at their next
rebuild. So a plain remove of one stops with `profile-removal` (exit 3), naming those machines, and
writes nothing: `--uninstall` confirms the removal everywhere; `--keep-here` keeps it on this
machine only (its table gets `machines` with this machine's name, under the subject
`feat: keep NAME on <machine> only`), the way a component is scoped to one machine. The host file of
a machine cannot carry a component (it can only decline one), so the scope goes into the table.

Stopping to track never uninstalls what the person keeps:

| Method | Without `--uninstall` | With `--uninstall`, once the removal is published |
| --- | --- | --- |
| `deb` | the packages stay installed; plain `apt upgrade` still updates them, nothing else follows them | `sudo apt-get remove` of the packages no other component names, on a terminal; without one `uninstall-required` with the command (exit 3), and the same `remove --uninstall` later runs it |
| `official-binary` | the binary stays | the binary and its companions are deleted when the binary is a file below HOME that answers the version probe of the component (`versionArgv`, `versionRegex`); else they stay, named |
| `pypi` | the virtual environment stays | the links that point into the environment, and the environment when it holds its `pyvenv.cfg`, both below HOME; a file of the same name that is no such link stays, named |
| `nix` | `profile-removal`: remove asks first | it leaves the Home Manager profile of every machine at their next rebuild |
| `system`, `app-archive`, `external` | stays | stays: remove it by hand |

What `--uninstall` may remove is worked out from the manifest mirror before the component goes,
kept in `<state>/track/uninstall-NAME.json`, and every path is checked again when it is removed. It
waits while the removal is not published (`--no-publish`, no network): the same
`remove --uninstall --publish` finishes it.

## What both do around the change

Both hold the instance lock; `maintain begin` and `apply` run nested in it, through the dispatcher.
Each commits only its own change: the paths of the component (`workstation.toml` where only the
lines of the table of NAME and its entry of the order differ, this machine's host file where only
what it says of NAME differs, `components/NAME/`, the mirrors under
`.dotsteward/`). Another change of the checkout or a commit the remote lacks is the question of
`maintain begin` (`checkout-dirty`, `unpublished-commits`): nothing is written, exit 3. What an
earlier run for the same component left, a red gate, a commit whose push waited for the network, is
its own, and the same command finishes it. `--with-changes` answers `checkout-dirty` for the
uncommitted changes the person agreed belong to it; commits the remote lacks stay a question. The questions `nonconventional-commits` and
`adaptive-route` stop it the same way; `settings-local` is only a note.

`--json` prints one document: `command`, `component`, `channel` (`add`), `change` (`added`,
`enabled`, `changed`, `removed`, `unchanged`, or null when nothing was looked at), `ask`, `notes`,
`apply` (the report of the `apply` it ran, else null), `here`, `reason` and `with_changes` (`add`),
`uninstall` (`remove`: `status`, `run`, `removed`, `kept`) and `exit_code`. Each run leaves a report in `<state>/runs/add/` or `runs/remove/`, and
its questions in `review.json`. After a green publish of a tree it activated, `apply` records the state of this machine on its
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
