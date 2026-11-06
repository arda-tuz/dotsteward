# Run state, resuming and recovery

Every contribution is one run with one state file, `<state root>/contribute/<id>.json` (mode 0600; `state.root` of `dotsteward context --json` is the state root), where the id is `<UTC timestamp>-<slug>`. `<state root>/contribute/current` names the current run; the steps act on it unless `--id ID` names another one. Every step reads the file and updates it, so an interrupted run resumes where it stopped.

## Reading the state

```bash
dotsteward contribute status --json
```

A long step (`check`, `trial`, `publish`, `release`, `upgrade`, `abort`, `report`) that runs in the background is waited for, never polled:

```bash
dotsteward contribute status --wait --timeout 540
```

It blocks until no step of the run runs, prints the state and exits with the status of the run's last step (exit 3: the timeout passed first; run it again).

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
| `running` | while a long step works: its `step`, `pid` and `started_at` (UTC); every other step refuses meanwhile |
| `promote` | only in a run started with `--promote NAME`: the private component the run moves into the catalog, the one name its instance-leak scan exempts |
| `last_step` | the last long step that ended: `step`, its exit `status` (`null` when its process vanished without ending it), `started_at` and `ended_at` |

The remote steps add `profile` (the profile of the trial, recovery and upgrade), `trial` and `trial_sha` (full or build-only, and the commit it passed for), `upgrade` (full or build-only), `upgrade_to` (the release tag, or `main` when the upgrade follows the merged commit), `instance_base` (the instance commit the upgrade started from), `upgrade_commit` (the framework upgrade commit of the instance), `carry` (the instance commits carried across the upgrade with `--carry`: `head`, `remote`, `commits` and `applied`), `recovery` (`done` or `failed`) and `outcome` (`completed`: the instance was upgraded; `published`: the run ended at publish, without a release tag or an instance commit; `aborted`). Once the run has a merged commit, `status` also shows `main_ci`, main's CI for that commit (`state` pending, green, red or unknown, its `url` and `runs`), read once from GitHub.

## Resuming

`step` names what runs next:

| `step` | Next command |
| --- | --- |
| `reproduce` | write the test, then `dotsteward contribute check --expect-fail <test path>` |
| `fix` | commit the test (`dotsteward contribute commit --test`), write and commit the fix (`dotsteward contribute commit`), then `dotsteward contribute check` |
| `check` | `dotsteward contribute check` |
| `trial` | `dotsteward contribute trial` (or `--build-only`) |
| `publish` | `dotsteward contribute publish` |
| `release` | `dotsteward contribute release` when a release commit is pending; otherwise `dotsteward contribute upgrade --main` or `dotsteward contribute report` (the run ends at publish) |
| `upgrade` | `dotsteward contribute upgrade --tag <tag>`, or `--main` when it follows the merged commit, with `--carry` when it carries instance commits |
| `report` | `dotsteward contribute report` |
| `done` | nothing: the run is finished |

`dotsteward contribute start --slug SLUG` with the slug of an unfinished run switches the clone back to its branch and makes it the current run again. A step that is not the next one refuses and names the next command.

## Exit status of the steps

- `0`: the step is done; the output names the next command.
- `1`: refused or red. Nothing was published by this step; read the message, fix the cause, and run the named command. A step refused because another one is running names it: wait for that one (`dotsteward contribute status --wait`), never start it twice.
- `3` (`status --wait --timeout`): the step still runs; wait again.
- `4` (`check`): privacy hard stop. The findings are redacted to a rule and a location. Remove them from every commit of the branch and run `check` again; nothing may be published before it passes.
- `5` (`publish`): back to `check`. The upstream `main` moved or the merged tree differed; the branch was rebased (or must be rebased by hand after a conflict) and the tested commit is gone.

## Recovery after a trial switch

A full trial switches the live generation to the candidate framework (`trial_switched` becomes true). Until the upgrade has switched the machine to the released framework, the framework skill links and the CLI on this machine come from that trial commit. Whenever the run ends without a successful upgrade (a red step, a privacy stop, red CI, the user's decision, or `report` at step `release`, which ends a run at publish), the recovery returns the machine to the instance's pinned framework: `rebuild --switch` without an override, then `e2e`.

- Red steps after a trial switch run the recovery themselves before they exit, except `release`: its change is merged with the tested tree, so the trial framework is what `main` has; the machine keeps it until the upgrade switches to the release, or until `abort` or `report` end the run with the recovery. Run `release` again once the cause is fixed.
- To end a run on purpose, at any step before `done`:

  ```bash
  dotsteward contribute abort
  ```

  Abort runs the recovery first and finishes the run only when it succeeded. A failed recovery (`recovery` is `failed`) says why: uncommitted instance changes block the rebuild (finish them with the upgrade or remove them), or the rebuild or `e2e` failed. Fix the cause and run `dotsteward contribute abort` again; it resumes at the part that failed.
- Abort never undoes what is already public: a merged commit stays on `main`, and an open pull request stays open (close it when it is no longer wanted).

The report states whether a recovery ran, so the user knows which framework the machine uses.
