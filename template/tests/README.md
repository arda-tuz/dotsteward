# Instance tests

Checks of your own that run with the framework's static checks: rules about
your files that no framework check knows, such as a key that must stay in a
settings file or a file that must keep a given form.

List each script in `workstation.toml`:

```toml
[gate]
static = ["tests/static.sh"]
```

Every listed script must exist and be executable. They run, in order, from the
instance root:

- in `dotsteward static`, after every selected framework check passed; the
  `static` step of `dotsteward gate` runs them outside the sandbox, after
  the privacy scan;
- in the Nix build sandbox, as `checks.<system>.instance-static`, which
  `nix flake check` builds: no network, no home directory, no git metadata.

A shell script runs with bash, any other script through its shebang. The
environment carries:

| Variable | Value |
| --- | --- |
| `DOTSTEWARD_INSTANCE_ROOT` | the instance root (also the working directory) |
| `DOTSTEWARD_SANDBOX` | `1` inside the Nix build sandbox, else `0` |
| `DOTSTEWARD_STATIC_HELPER` | a bash file to source; it defines `fail MESSAGE`, which reports MESSAGE and makes the script fail, `own_files` and `framework_paths` (below) |

A script fails with a non-zero exit status; the first failing script ends the
run with its status. An example `tests/static.sh`:

```
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null # provided at run time
source "$DOTSTEWARD_STATIC_HELPER"

[[ -f home/AGENTS.md ]] || fail "home/AGENTS.md is missing"
if [[ $DOTSTEWARD_SANDBOX == 0 ]]; then
  : # checks that need git or the network
fi
```

`own_files` prints the files of the instance that the framework does not own,
one per line and sorted: what git carries (tracked files and untracked ones it
does not ignore), or every file below the root in the sandbox.
`framework_paths` prints the paths the framework owns (`.dotsteward/`,
`bootstrap.sh`, the skills lock, the vendored skills, `agent/plugins/`,
`agent/skill-licenses/`, `hosts/`; a directory ends in `/`): its commands write
them and its checks check them, and a new release may add one. A list of your
own files checked against `own_files` therefore needs no edit when the
framework starts to write a new path, and still names a file you did not
expect:

```
expected=$(printf '%s\n' README.md flake.lock flake.nix home.nix tests/static.sh \
  versions.lock.json workstation.toml)
[[ $(own_files) == "$expected" ]] || fail "unexpected files: $(own_files | tr '\n' ' ')"
```

Keep these scripts fast and deterministic, and free of secrets: they are part
of the gate.
