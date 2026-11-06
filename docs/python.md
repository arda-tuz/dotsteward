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

### Versions

`dotsteward_cli.versions` is the one version order: `compare(left, right)`,
`at_least(version, minimum)`, `newest(versions)` and `sort_key` for `sorted`
and `max`. A release sorts after its pre-releases (`1.2.3-rc1`, `1.2.3~rc1`)
and before its package revisions (`1.2.3-1`); the module documents the rest.
From bash: `ds_internal version-compare LEFT RIGHT` prints -1, 0 or 1, and
hooks keep `methods_version_compare` and `methods_version_at_least`. Two things
stay outside on purpose: `dpkg --compare-versions` for installed packages,
and stage 0, which checks operating system versions before Python exists.
