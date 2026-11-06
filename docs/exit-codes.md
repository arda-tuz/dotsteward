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
| `bootstrap` | 0, 1, 3, child | 1 also when another command holds the instance lock; 3: the preflight took the adaptive route; nothing was written |
| `component` | the hook's status, 1 | 1 also when the component or hook is unknown or inactive |
| `context` | 0, 1 | |
| `contribute` | 0, 1, 3, 4, 5 | 3: `status --wait --timeout` returned while a step still runs; 4: privacy hard stop, nothing may be published; 5: upstream main moved, the run goes back to `check` |
| `doctor` | 0, 1 | 1: at least one health check failed |
| `e2e` | 0, 1 | |
| `gate` | 0, 1 | 0 also when the memo answers for an unchanged tree |
| `generate` | 0, 1, 2 | 1 and 2 as for `pins`, from the `pins sync` it runs |
| `host` | 0, 1, 2, 4, 6 | 2: usage error; `host publish`: 4 a privacy finding and 6 no network or no login, in both cases nothing was published; 6 asks to run it again |
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
| `skills` | 0, 1, 2 | 2: usage error |
| `static` | 0, 1, script | otherwise the status of the failing instance script of `gate.static` |
| `sync` | as `generate` | the old name of `generate`: a warning on standard error, then the same arguments, output and status |
| `txn` | 0, 1 | `txn publish` exits 0 when the commit is already published |
| `update` | as `txn` | the old name of `txn`: a warning on standard error, then the same arguments, output and status |
| `version` | 0, 1 | 1: usage error |

`--json` never changes the exit code: a command that prints a failed result
document also exits non-zero.

## Run reports and review.json

A command with many steps can end in several ways at once. It reports the
heaviest outcome of the run, in the order 4, 1, 3, 6, 0:

| Code | Status | Meaning |
| --- | --- | --- |
| 4 | `privacy-stop` | a privacy stop: nothing may be published |
| 1 | `failed` | a refusal or a failed step, a red check that could not be rolled back among them |
| 3 | `pending` | a decision or a sudo step waits: see `review.json` |
| 6 | `partial` | no network, or the network steps were skipped; the checks ran |
| 0 | `ok` | done |

3 is what it is in `settings`, and 4 what it is in `contribute`; the other uses of
3 in the table above stay with their commands. `2` and `5` are no outcomes of a run:
`2` is a usage error or broken input before anything ran, as in `init` and `pins`,
and `5` keeps its meaning in `contribute`. A child that exits with any status but 0,
3, 4 and 6 counts as `failed`, and its step keeps the status as `exit_status`.

Each run leaves a report in `<state>/runs/<command>/<run>.json`
(`schema/run-report.schema.json`), of which the newest stay in the order of their
`sequence`, not of the clock. What needs a person or an agent is in
`<state>/review.json` (`schema/review.schema.json`), one file for every command, for
example:

```json
{
  "schema_version": 1,
  "status": "pending",
  "exit_code": 3,
  "runs": {
    "upgrade": { "run": "2026-11-03T080000Z-1a2b", "status": "pending", "exit_code": 3 }
  },
  "items": [
    { "command": "upgrade", "code": "sudo-required", "run": "dotsteward upgrade" }
  ]
}
```

Both stay on the machine and are never published. A run replaces the items of its
own command and leaves those of the others; `status` and `exit_code` are the heaviest
of the runs, and the file goes when the last item goes. [python.md](python.md) has the
interface.

See [cli.md](cli.md) for the options of every command.
