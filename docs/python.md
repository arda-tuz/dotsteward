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

## Calling the package from bash

`cli/lib/python.sh` holds the glue for the bash commands, which source it next
to `lib.sh`. `ds_python MODULE [ARG...]` runs a module of the package and
`ds_internal ARG...` the internal command line of the primitives
(`dotsteward_cli.internal`), which is no command of the CLI and may change
with the framework.

## Primitives

Every part of the framework uses these, so each answer exists once.

### Atomic writes

`dotsteward_cli.atomic.atomic_write(path, data, *, mode=None, parents=False)`
replaces a file through a temporary file in its directory, fsync, rename and an
fsync of the directory, so a reader sees the old file or the new one, also after
a crash. A write without `mode` keeps the mode of the file it replaces, else
0644; `parents` creates missing directories; the next write removes what a dead
writer left. `atomic_write_json` takes the same arguments and writes indented
JSON. From bash: `ds_internal atomic-write PATH [--mode MODE] [--parents]` writes
its standard input.

### Locks

`dotsteward_cli.locks.instance_lock(name, *, state_root=None, pending=None, pending_env=None, wait=0.0)`
holds `<state>/instance.lock`, which `apply`, `upgrade`, `bootstrap` and `observe`
share, for the block of a `with` statement. It uses `fcntl.flock`, so it needs no
flock binary, and the kernel drops the lock of a dead holder. When another
command holds it, `LockBusy` names the holder at once. With `pending=ARGV` a
marker stays in `<state>/instance.pending/`, and the holder starts `ARGV` when it
lets go; that command asks for the lock itself. A command under the lock can run
another that asks for it, which runs nested. A process a command leaves behind
does not keep the lock. The gate's own lock nests inside.
`lock_status(state_root)` tells who holds it; to act on a free lock, acquire it.
`FileLock(path)` is the same primitive for a lock of another file, for example
one that only skill capture takes. From bash:

```sh
ds_internal lock run --holder NAME --state-root "$(state_root)" -- COMMAND ARG...
```

Busy, it exits 1; with `--pending` it leaves a marker and exits 0; with
`--wait SECONDS` it tries for a while. `ds_internal lock status` prints JSON.

### Protected children

`dotsteward_cli.procs.run_protected(argv, *, cwd=None, env=None, stdin=DEVNULL)`
runs a child that must not stop half way, such as a package manager, in a process
group of its own, and keeps SIGINT, SIGTERM and SIGHUP until it has ended. The
result has its `returncode` and the names of the signals in `interrupted`. The
child must not read the terminal: ask for credentials before. From bash:
`ds_internal run-protected -- COMMAND ARG...`.

### State root

`dotsteward_cli.config.state_root(instance=None, env=None)` is the one machine
state root: `DOTSTEWARD_STATE_ROOT`, then `DOTFILES_STATE_ROOT` with
`compat.legacy_env`, then `state.root` of the instance, then the default of
`schema/workstation.schema.json`. `discovered_state_root(env=None)` looks the
instance up first. From bash: `ds_internal state-root [--instance DIR]`, and
`state_root` of `lib.sh` after `config_load`, which a test holds to the same
answer.

### TOML

`dotsteward_cli.tomlfile` is the one TOML reader: `load(path)` and `loads(text)`
give a plain document and raise `TomlError` for text that is not TOML. The two
modules that edit TOML files and keep their comments (`init` and the settings
engine) use tomlkit. `privacy/policy.toml` is read in bash, because the pre-push
hook runs before any Python is available.

### Versions

`dotsteward_cli.versions` is the one version order: `compare(left, right)`,
`at_least(version, minimum)`, `newest(versions)` and `sort_key` for `sorted`
and `max`. A release sorts after its pre-releases (`1.2.3-rc1`, `1.2.3~rc1`)
and before its package revisions (`1.2.3-1`); the module documents the rest.
From bash: `ds_internal version-compare LEFT RIGHT` prints -1, 0 or 1, and
hooks keep `methods_version_compare` and `methods_version_at_least`. Two things
stay outside on purpose: `dpkg --compare-versions` for installed packages,
and stage 0, which checks operating system versions before Python exists.
