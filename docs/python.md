# The Python package

New commands of the `dotsteward` CLI are written in Python; the bash commands
stay until they are rewritten, and the bash library that component hooks use
is frozen. This page describes the one Python package of the framework.

## Layout

`pyproject.toml` declares one distribution, `dotsteward`, with three source
roots. The files stay where they are, because the paths are a contract: the
commands, the Nix checks and the Python tests of instances import from them.

| Source root | Import name | Contents |
| --- | --- | --- |
| `cli/python` | `dotsteward_cli` | the configuration reader, `context`, `doctor`, `init`, the primitives below; new commands go here |
| `engines/pins` | `dotsteward_pins` | the pins engine ([pins-engine.md](pins-engine.md)) |
| `engines/local-maintained-files` | `local_maintained_files`, `jsonc`, `lmf_validate` | the settings engine ([settings-buffer.md](settings-buffer.md)) |

`dotsteward_cli` is the base: the engines import it, it imports neither. The
dependencies of the package are what the CLI package puts into its python
(`nix/packages/dotsteward.nix`), a test keeps the two equal, and that python
comes from Nix, never from the system. The CLI runs from the source tree of
the package with `python3 -s -P -m <module>` and `PYTHONPATH` naming the source
roots it needs; the wheel exists only to prove the declaration holds every
module.

The Python tests of instances put `engines/pins` and `cli/python` on `sys.path`
and import `dotsteward_pins.checker`, `.instance`, `.lockfile`, `.rules`,
`.latest.core` and `.latest.adapters`; `tests/cli/core/test-package.sh` keeps the
names they use.

## Checks

`pyproject.toml` holds the one configuration of ruff and of mypy in strict
mode. `checks.python-core` runs both over all Python of the framework, builds
the wheel and runs the tests in `tests/cli/core`, and the `lint` job of
`.github/workflows/ci.yml` builds that check on every event:

```sh
nix build -L --no-link .#checks.x86_64-linux.python-core
```

Fix a finding or type the code; an ignore is narrow, names its rule and says
why on the same line.

## A new command

A command is a module of `cli/python/dotsteward_cli` with a thin file
`cli/commands/<name>.sh`, which the dispatcher finds by its name:

```text
#!/usr/bin/env bash
# summary: What the command does
# shellcheck source=cli/lib/python.sh
source "$DOTSTEWARD_LIB/python.sh"
ds_python_exec dotsteward_cli.example "$@"
```

Docs follow as for every command: `docs/exit-codes.md` gets a row, and
`tools/gen-docs.sh` writes `docs/cli.md`.

## Calling the package from bash

`cli/lib/python.sh` holds the glue for the bash commands, which source it next
to `lib.sh`. `ds_python MODULE [ARG...]` runs a module of the package with every
source root on its path, `ds_python_exec` does so in place of the shell, and
`ds_internal ARG...` runs the internal command line of the primitives
(`dotsteward_cli.internal`), which is no command of the CLI and may change
with the framework.

## Primitives

Every part of the framework uses these, so each answer exists once.

### Atomic writes

`dotsteward_cli.atomic.atomic_write(path, data, *, mode=None, parents=False)`
replaces a file through a temporary file in its directory, a sync, rename and a
sync of the directory, so a reader sees the old file or the new one, also after a
crash, and after a power cut as far as the disk keeps what a sync asks of it (macOS:
`F_FULLFSYNC` where the file system knows it). A write without `mode` keeps the mode of
the file it replaces, else 0644, but not its owner: the file belongs to the user who
writes it. `parents` creates missing directories; the next write removes what a dead
writer left. `atomic_write_json` takes the same arguments and writes indented JSON.
`make_private_dirs(path)` creates a directory with mode 0700; parents it has to create
follow the umask, so call it for the state root first when that may be new too. From
bash: `ds_internal atomic-write PATH [--mode MODE] [--parents]` writes its standard input.

### Locks

`dotsteward_cli.locks.instance_lock(name, *, state_root=None, pending=None, pending_env=None, wait=0.0)`
holds `<state>/instance.lock`, which `apply`, `upgrade`, `bootstrap` and `observe`
share, for the block of a `with` statement. Without `state_root` it is
`config.required_state_root()`: the state root of the instance that discovery finds,
or `DOTSTEWARD_STATE_ROOT`. Without either it raises `DotstewardError`, since a default
would be another lock than the one of the instance. It uses `fcntl.flock`, so it needs
no flock binary, and the kernel drops the lock of a dead holder. When another command
holds it, `LockBusy` names the holder at once. A command under the lock can run another
that asks for it, which runs nested. A process a command leaves behind does not keep the
lock: when a holder dies from SIGKILL, its child goes on without the lock and the next
command can start beside it. The gate's own lock nests inside.

With `pending=ARGV` a marker stays in `<state>/instance.pending/`, and the holder starts
`ARGV` when it lets go, with the output in `instance.pending/NAME.log`; that command asks
for the lock itself. A holder that dies starts nothing, so the next holder does. A marker
has no expiry: `lock_status` gives its age in `pending_since`. `ARGV` runs when its paths
may be gone or belong to an older framework, so give it a path that stays, such as the
`dotsteward` of the profile. A command that can never start is dropped with a warning; a
passing failure, such as a full disk, leaves the marker for the next holder.

A pending command gets the variables of `pending_environment()` from the command that
asked, and `pending_env`. They are `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`,
`LANGUAGE`, `LC_*`, `TZ`, `TMPDIR`, `XDG_*`, `SSH_AUTH_SOCK`, `DISPLAY`, `WAYLAND_DISPLAY`,
`DBUS_SESSION_BUS_ADDRESS`, `DOTSTEWARD_INSTANCE`, `DOTSTEWARD_STATE_ROOT`, `DOTFILES_ROOT`
and `DOTFILES_STATE_ROOT`. Nothing of the holder's reaches it, and the whole environment
is never written to a marker, so no secret lands on disk. What decides how a command
behaves, such as `DOTSTEWARD_ASSUME_YES` or a `DS_*` variable, stays out unless it is in
`pending_env`.

`lock_status(state_root)` tells who holds it; to act on a free lock, acquire it.
`FileLock(path)` is the same primitive for a lock of another file, for example
one that only skill capture takes: `try_acquire(wait=0.0)`, a blocking `acquire()`
and `release()`. From bash:

```text
ds_internal lock run --holder NAME --state-root "$(state_root)" -- COMMAND ARG...
```

Its status is the status of `COMMAND`. Busy, it exits 1, which a `COMMAND` can also do: the
Python interface keeps the two apart with `LockBusy`. With `--pending` it leaves a marker
and exits 3, and `COMMAND` has the same environment whether the lock is free or busy. That
marker names the Python of this framework: after an upgrade it still runs the older framework,
and after a garbage collection it is dropped with a warning. For a long wait, use the Python
interface with a path that stays. With `--wait SECONDS` it tries for a while. Without
`--state-root` the state root is the required one above. `ds_internal lock status` prints JSON,
also the `pending_since` of each marker.

### Protected children

`dotsteward_cli.procs.run_protected(argv, *, cwd=None, env=None, stdin=DEVNULL, stdout=None, stderr=None)`
runs a child that must not stop half way, such as a package manager, in a process
group of its own, and keeps SIGINT, SIGTERM and SIGHUP until it has ended. The
result has its `returncode` and the names of the signals in `interrupted`. The
child must not read the terminal: ask for credentials before. It writes to the
terminal unless `stdout` and `stderr` say otherwise, and once the terminal has closed
such a write fails, so a child that stops on a failed write stops half way. A child that
has to finish writes to a file. From bash:
`ds_internal run-protected [--log FILE] -- COMMAND ARG...`, where `--log` appends both
streams to `FILE`. Its status is the status of `COMMAND`, also when the terminal is gone.

### Publishing

`dotsteward_cli.publish.publish(repository, branch, scope, build)` is the one way to
the remote of an instance: it fetches the branch into `refs/dotsteward/<scope>/tip`, calls
`build(tip)` for a commit on that tip (`None`: nothing to publish), pushes it without force
and starts again on the new tip when the remote moved. The result says `OK`, `NETWORK`,
`REFUSED` or `EXHAUSTED`, with the commit that landed and what git said; a push that ends
without an answer is settled by a fetch. `classify(result)` names a failure of git: nothing
was decided, the remote said no, or the remote moved.

### Run reports

`dotsteward_cli.report.RunReport(command, state_root, *, run=None)` collects a
run: `step(name, code=OK, **details)`, where `code` may be the status of a child
(`outcome_of(status)`), `item(code, *, pending=True, **fields)` for `review.json`,
`data` for what the next run needs, `mark_interrupted(signals)`. `exit_code` and
`status` give the heaviest outcome, in the order 4, 1, 3, 6, 0 (`combine(codes)`),
`write()` writes the files atomically, and `load_last(state_root, command)` and
`load_review(state_root)` read them back. `review.json` is one file for every command;
a run replaces the items of its own. The outcomes are `OK`, `FAILED`, `PENDING`,
`PRIVACY_STOP` and `PARTIAL`; [exit-codes.md](exit-codes.md) explains them and the
files. From bash: `ds_internal report combine CODE...` prints the heaviest code, and
`ds_internal report write --command NAME` writes a report from JSON on standard input
and exits with its code.

### State root

`dotsteward_cli.config.state_root(instance=None, env=None)` is the one machine
state root: `DOTSTEWARD_STATE_ROOT`, then `DOTFILES_STATE_ROOT` with
`compat.legacy_env`, then `state.root` of the instance, then the default of
`schema/workstation.schema.json`. `discovered_state_root(env=None)` looks the
instance up first. `required_state_root(env=None)` does too, and has no default: outside
an instance and without `DOTSTEWARD_STATE_ROOT` it raises `DotstewardError`. It is for what
commands share at the state root, such as a lock: the default would be another place than
the `state.root` of the instance a second command runs in. From bash:
`ds_internal state-root [--instance DIR]`, and `state_root` of `lib.sh` after `config_load`,
which a test holds to the same answer.

### TOML

`dotsteward_cli.tomlfile` is the one TOML reader: `load(path)` and `loads(text)`
give a plain document and raise `TomlError` for text that is not TOML. The three
modules that edit TOML files and keep their comments (`init`, `host` and the
settings engine) use tomlkit. `privacy/policy.toml` is read in bash, because the pre-push
hook runs before any Python is available.

### Machines

`dotsteward_cli.machine` holds the name of this machine and what applies to it
([machines.md](machines.md)). `effective(instance, env=None)` is the one answer: `{name,
profile, tags, skip: {components, skills, plugins}, reasons}`. Nothing stores it, and a new
reason to leave something out goes there, so every command follows. `name_taken` lists the
skills of the lock that are for other machines while this one has a skill of that name.
`read_machine`, `write_machine` and `current_name` read and write `<state>/machine.json`,
and `known_names`, `read_host` and `parse_host` read `hosts/<name>.toml`, which
`check_problems` holds to its rules. `config.schema_errors(document, raw)` checks a TOML
document against any schema of the keyword subset, and `config.newer_tree_hint(root,
problems)` words the way out of a tree newer than the CLI. From bash, every command that
ran `config_load` has `DS_MACHINE_NAME` and the JSON lists `DS_SKIP_COMPONENTS_JSON`,
`DS_SKIP_SKILLS_JSON` and `DS_SKIP_PLUGINS_JSON`.

### Versions

`dotsteward_cli.versions` is the one version order: `compare(left, right)`,
`at_least(version, minimum)`, `newest(versions)` and `sort_key` for `sorted`
and `max`. It is the algorithm of dpkg behind a small pre-pass, so it gives
dpkg's answer on package versions and is a real order. A release sorts after
its pre-releases (`1.2.3-rc1`, `1.2.3~rc1`, `1.2.3rc1`, `1.2.3.dev0`) and before
its package revisions (`1.2.3-1`) and what follows `+` (`1.2-1+esm1`); the module
documents the rest.
From bash: `ds_internal version-compare LEFT RIGHT` prints -1, 0 or 1, and
hooks keep `methods_version_compare` and `methods_version_at_least`. Two things
stay outside on purpose: `dpkg --compare-versions` for installed packages,
and stage 0, which checks operating system versions before Python exists.
