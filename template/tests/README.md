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

- in `dotsteward static`, after every framework check passed; that is the
  `static` step of `dotsteward gate` (`./update.sh validate`);
- in the Nix build sandbox, as `checks.<system>.instance-static`, which
  `nix flake check` builds: no network, no home directory, no git metadata.

A shell script runs with bash, any other script through its shebang. The
environment carries:

| Variable | Value |
| --- | --- |
| `DOTSTEWARD_INSTANCE_ROOT` | the instance root (also the working directory) |
| `DOTSTEWARD_SANDBOX` | `1` inside the Nix build sandbox, else `0` |
| `DOTSTEWARD_STATIC_HELPER` | a bash file to source; it defines `fail MESSAGE`, which reports MESSAGE and makes the script fail |

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

Keep these scripts fast and deterministic, and free of secrets: they are part
of the gate.
