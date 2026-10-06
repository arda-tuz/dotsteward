# Run state, resuming and recovery

Every contribution is one run with one state file, `<state root>/contribute/<id>.json` (mode 0600; `state.root` of `dotsteward context --json` is the state root), where the id is `<UTC timestamp>-<slug>`. `<state root>/contribute/current` names the current run; the steps act on it unless `--id ID` names another one. Every step reads the file and updates it, so an interrupted run resumes where it stopped.

## Reading the state

```bash
dotsteward contribute status --json
```

| Field | Meaning |
| --- | --- |
| `id` | the run id |
| `slug` | the change name; the branch is `fix/<slug>` |
| `mode` | `owner` or `fork`, fixed when the run started |
| `clone` | the framework clone of the run |
| `branch` | the run's branch in the clone |
| `base_sha` | the upstream `main` the branch started from |
| `test_sha` | the commit the framework gate (`check`) passed for |
| `tested_tree` | the tree of that commit; the published commit must have it |
| `trial_switched` | true while the live generation uses the trial framework |
| `pr` | the pull request URL (owner mode, or a fork's upstream pull request) |
| `merged_sha` | the commit on the target `main` |
| `tag` | the release tag |
| `instance_commit` | the instance commit of the upgrade |
| `step` | the next step of the run |

The remote steps add `profile` (the profile of the trial, recovery and upgrade), `trial` and `trial_sha` (full or build-only, and the commit it passed for), `upgrade` (full or build-only), `instance_base` (the instance commit the upgrade started from), `recovery` (`done` or `failed`) and `outcome` (`completed` or `aborted`).

## Resuming

`step` names what runs next:

| `step` | Next command |
| --- | --- |
| `reproduce` | write the test, then `dotsteward contribute check --expect-fail <test path>` |
| `fix` | write the fix, then `dotsteward contribute check` |
| `check` | `dotsteward contribute check` |
| `trial` | `dotsteward contribute trial` (or `--build-only`) |
| `publish` | `dotsteward contribute publish` |
| `release` | `dotsteward contribute release` |
| `upgrade` | `dotsteward contribute upgrade --tag <tag>` |
| `report` | `dotsteward contribute report` |
| `done` | nothing: the run is finished |

`dotsteward contribute start --slug SLUG` with the slug of an unfinished run switches the clone back to its branch and makes it the current run again. A step that is not the next one refuses and names the next command.

## Exit status of the steps

- `0`: the step is done; the output names the next command.
- `1`: refused or red. Nothing was published by this step; read the message, fix the cause, and run the named command.
- `4` (`check`): privacy hard stop. The findings are redacted to a rule and a location. Remove them from every commit of the branch and run `check` again; nothing may be published before it passes.
- `5` (`publish`): back to `check`. The upstream `main` moved or the merged tree differed; the branch was rebased (or must be rebased by hand after a conflict) and the tested commit is gone.

## Recovery after a trial switch

A full trial switches the live generation to the candidate framework (`trial_switched` becomes true). Until the upgrade has switched the machine to the released framework, the framework skill links and the CLI on this machine come from that trial commit. Whenever the run ends without a successful upgrade (a red step, a privacy stop, red CI, or the user's decision), the recovery returns the machine to the instance's pinned framework: `rebuild --switch` without an override, then `e2e`.

- Red steps after a trial switch run the recovery themselves before they exit.
- To end a run on purpose, at any step before `done`:

  ```bash
  dotsteward contribute abort
  ```

  Abort runs the recovery first and finishes the run only when it succeeded. A failed recovery (`recovery` is `failed`) says why: uncommitted instance changes block the rebuild (finish them with the upgrade or remove them), or the rebuild or `e2e` failed. Fix the cause and run `dotsteward contribute abort` again; it resumes at the part that failed.
- Abort never undoes what is already public: a merged commit stays on `main`, and an open pull request stays open (close it when it is no longer wanted).

The report states whether a recovery ran, so the user knows which framework the machine uses.
