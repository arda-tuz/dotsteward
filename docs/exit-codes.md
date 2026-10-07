# Exit codes

Every `dotsteward` command follows one convention, with a few documented
additions:

- `0`: the command did what it was asked, or what it checked holds.
- `1`: a refusal (a guard failed before any change, or the arguments are
  wrong) or a failed check.
- Any other status of a bash command is the status of a child command that
  failed (the commands run under `set -Eeuo pipefail`), unless the table
  gives it a meaning.

An unknown command exits 1 and lists the available ones. Skills and scripts
should test for the documented codes only and treat any other non-zero
status as a failure.

| Command | Exit codes | Additions to the convention |
| --- | --- | --- |
| `agents` | 0, 1, child | |
| `bootstrap` | 0, 1, 3, child | 3: the preflight took the adaptive route; nothing was written |
| `component` | the hook's status, 1 | 1 also when the component or hook is unknown or inactive |
| `context` | 0, 1 | |
| `contribute` | 0, 1, 4, 5 | 4: privacy hard stop, nothing may be published; 5: upstream main moved, the run goes back to `check` |
| `doctor` | 0, 1 | 1: at least one health check failed |
| `e2e` | 0, 1 | |
| `gate` | 0, 1 | 0 also when the memo answers for an unchanged tree |
| `init` | 0, 1, 2 | 2: usage error; on 1 and 2 the directory is left as it was |
| `install` | 0, 1, 3 | 3: the preflight took the adaptive route and stopped the phase |
| `login-shell` | 0, 1, child | |
| `pins` | 0, 1, 2 | 1: inconsistencies or a refusal; 2: usage error or broken input (no instance, invalid configuration, invalid manifest mirror or rule, unreadable lock file, failed Nix evaluation) |
| `preflight` | 0, 1, 3 | 0: fast route; 3: adaptive route (after a warning) |
| `probes` | 0, 1 | |
| `rebuild` | 0, 1, child | |
| `rollback` | 0, 1, child | |
| `scan` | 0, 1 | 1: at least one finding (all are collected first) or an error |
| `settings` | 0, 1, 2, 3 | 1: `verify` found a difference; 2: error; 3: a decision is pending (a conflict or a local deletion; resolve it with `settings resolve`) |
| `static` | 0, 1, script | otherwise the status of the failing instance script of `gate.static` |
| `sync` | 0, 1, 2 | 1 and 2 as for `pins`, from the `pins sync` it runs |
| `update` | 0, 1 | `update publish` exits 0 when the commit is already published |
| `version` | 0, 1 | 1: usage error |

`--json` never changes the exit code: a command that prints a failed result
document also exits non-zero.

See [cli.md](cli.md) for the options of every command.
