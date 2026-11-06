# Publish, release and upgrade

What `dotsteward contribute publish`, `release` and `upgrade` do in each mode, what they refuse, and what the skill does next. The commands print the next step on every refusal; follow it.

## Preconditions of publish

- The run passed `check` (the framework gate) and `trial` for the current commit of the branch: the clone is clean, on the run's branch, at the checked commit. A new commit after the gate means `check` and `trial` again.
- `VERSION` of the checked commit is either the release its commits are based on (the run releases nothing) or exactly the next release, set by a release commit (`references/framework-change.md`); checked before anything is pushed and again before the merge, since a release cut meanwhile moves the next one.
- `gh` is installed and logged in (`gh auth login` otherwise).
- After a build-only trial, the `clean-install.yml` workflow must also be green on the checked commit; publish dispatches it on the branch when it has not run. If GitHub Actions are disabled on the target repository, run a full trial instead.

## A network that drops

A `git ls-remote`, fetch or push that fails for the network (a connection that times out, a name that does not resolve, an answer that never comes) and a read of GitHub that fails (`gh`) say nothing about the change: `publish` and `release` make them again after a pause that starts at `DOTSTEWARD_CONTRIBUTE_POLL_SECONDS` and doubles, with a warning each time, and stop red only when the failures lasted `DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS`. A push reads its ref again first, because a push whose answer was lost has landed. A push the remote refuses (a protected branch, a `main` that moved), a finding of the pre-push hook, a refused login, a repository that does not exist and a failure on this machine (no `ssh`) are verdicts: never made again. So are words the CLI does not know as those of a failed connection: they get one attempt. Writes through `gh` (creating a pull request, dispatching a workflow) are made once; a rerun of `publish` finds what they left. The instance commands that `upgrade` runs (`e2e`, `update publish`) read and push once: a drop there turns the upgrade red, and it is safe to run again.

## Owner mode

1. Pushes `fix/<slug>` to the upstream (the pre-push hook scans the pushed commits and tree with the denylist).
2. Opens the pull request, or reuses the open one of the branch.
3. Waits for the lint and privacy checks of the pull request head: the `lint` job of `ci.yml` and the `generic` scans of `privacy.yml`. The full check (`nix flake check`, the `check` job of `ci.yml`) is skipped on a pull request of the repository; it runs on `main` after the merge, and `release` waits for it. Red CI: `main` is untouched; read the failing job (`gh run view --log-failed`), fix the cause in a new commit, then `check`, `trial` and `publish` again.
4. Requires the branch to be up to date with the upstream `main`. If `main` moved, publish rebases the branch onto it and exits 5: the run is back at `check` (the rebased commit has not been tested). A rebase conflict is left for you to resolve in the clone; then run `check`.
5. Merges by pushing the checked commit to the upstream `main`, which fast-forwards the upstream `main` to exactly the commits that passed the gate, with their author, committer and UTC dates; GitHub then records the pull request as merged. Never merge the pull request on GitHub (squash, merge or rebase button): GitHub writes a new commit with the account's display name and local time, which the privacy scans refuse on `main`. If `main` moved at the last moment, the push no longer fast-forwards: publish rebases the branch as in step 4 and exits 5. A push the upstream refuses (for example a protected branch) is red and `main` is untouched.
6. Verifies that the merged commit on `main` has exactly the tested tree. A pull request merged on GitHub by hand with other changes releases nothing: the branch is put on the merged `main`, publish exits 5, and the run goes back to `check`, which then checks the merged commit itself.

A closed pull request stops the run: reopen it, or end the run with `dotsteward contribute abort`.

## Fork mode

1. Pushes `fix/<slug>` to the fork and waits for the fork's CI on the checked commit.
2. Fast-forwards the fork's `main` to the checked commit and verifies that it has the tested tree (a mismatch stops the run red; nothing is released). If the fork's `main` has commits the branch lacks, the fast-forward is refused: rebase the branch onto the fork's `main` in the clone (with `TZ=UTC`), then `check`, `trial` and `publish` again. A merge commit is no way around it: the clone's commit-msg hook refuses git's default merge subject, on purpose.
3. Opens a pull request to the upstream only when `upstream.pr_to_upstream` is true in `workstation.toml` or the user asks for it; ask before opening one on someone else's repository:

   ```bash
   dotsteward contribute publish --pr-to-upstream
   ```

The release is then a tag on the fork, and the instance upgrades to the fork's tag until the upstream ships the change.

## Release

Releases are trains: a run does not need a release of its own, and a release bundles every commit since the last one. The release is the version `VERSION` of the merged commit names, which only a release commit sets (`references/framework-change.md`): semantic versioning from the conventional commits since the release the commits are based on, after the newest `v*` tag (any `feat` makes the next minor, anything else the next patch; from `0.0.0` without any tag). A breaking change makes the next major, which is cut only with `dotsteward contribute release --major`, after the user decided it.

`dotsteward contribute release` creates that tag as an annotated tag on the merged commit and pushes it. In owner mode it also creates the GitHub release with grouped notes: the subjects of the commits since the previous release under Features, Fixes and Other (`gh release create --notes-file ... --verify-tag`). It refuses when `VERSION` of the merged commit is not the next release, or when the tag already exists elsewhere (red with nothing changed). It is safe to rerun: an existing tag on the merged commit is kept.

Without a release commit (`VERSION` is still the release the commits are based on) there is nothing to release: `release` says so and changes nothing. End the run at publish with `dotsteward contribute report` (after a trial switch it first returns the machine to the pinned framework, as `abort` does): its outcome is `published`, and the next release bundles the change. Once `upgrade --main` has started, `report` refuses: finish that upgrade, or end the run with `abort`.

The release workflow (`release.yml`) cuts the same release without a run: once `ci.yml` passed on `main`, it releases a pending release commit (tag only, `tools/version.sh release`), and it can be dispatched on `main` (with the `major` input for a major release). It makes no commit, so the tag always names a commit whose full CI is green; a release the workflow cut first is reused by `release`. The workflow often cuts it while `release` still waits for `main`'s CI, so `release` reads the tag on `origin` again after that wait and after a push or a GitHub release that failed: the workflow's tag on the merged commit is the run's release, with no push and no second GitHub release. The other way round, `release` may create the GitHub release while the workflow is about to: the workflow then takes that release as its own when its tag names the same commit, and stays green.

A release is cut only from a `main` commit whose CI is green: before it tags, `release` waits for the push runs of `ci.yml` (lint and the full check) and `privacy.yml` on `main` for the merged commit, with the same limits as publish (`DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS` for the runs to appear, `DOTSTEWARD_CONTRIBUTE_CI_TIMEOUT_SECONDS` for them to finish). A read of GitHub that fails during the wait (the network is down for a moment, or GitHub answers HTTP 5xx) is no CI result: `release` makes it again after a pause that starts at `DOTSTEWARD_CONTRIBUTE_POLL_SECONDS` and doubles, and stops red only when the reads keep failing for `DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS`. A missing, red or unfinished run releases nothing and keeps the run at `release`, with the machine as it is (a red `release` runs no recovery, since the change is merged): read the failing job, and when the cause is a flaky runner, rerun the job on GitHub (`gh run rerun <id> --failed`); a defect needs a new run of this skill, since the merged commit stays on `main`. `dotsteward contribute status` shows that state at any time (`main_ci`). A fork without GitHub Actions has no CI to wait for; `release` warns and tags.

## Upgrade

`dotsteward contribute upgrade --tag <tag>` runs in the instance checkout, which must have no uncommitted changes:

1. `update prepare --scope maintain` (the instance `HEAD` must equal its remote branch; `git pull --ff-only` when it is behind),
2. the `dotsteward` input of `flake.nix` moved to the tag, then `nix flake update dotsteward`,
3. `bootstrap.sh` and `.dotsteward/cli.sh` refreshed from the release's `template/`, then `sync`,
4. the instance gate, then a commit with `commit.upgrade_subject` of the context,
5. `rebuild --switch` and `e2e` (no override), then `update publish --scope maintain`.

Once `flake.lock` pins the release, `sync`, the gate, the rebuild, `e2e` and the publish run through the instance launcher (`.dotsteward/cli.sh`), so the release's own CLI validates the upgraded instance.

The steps before that run the `dotsteward` on `PATH`, which after a full trial is the candidate's CLI of this run (`readlink -f "$(command -v dotsteward)"` names the build). `nix flake update dotsteward` resolves the `github:` input through GitHub's API, which Nix calls without authentication unless it has an access token, so it shares the quota of 60 unauthenticated requests an hour per IP address: when an agent has used it up, for example by polling `api.github.com` without authentication in a loop, the update fails until the quota resets. Read GitHub through `gh`, which is authenticated.

Without a release, the instance can follow the merged commit itself, the one this run's `check` and `trial` passed for (release trains: the run need not wait for a release):

```bash
dotsteward contribute upgrade --main
```

It pins the `dotsteward` input to that commit on the same repository URL (`github:OWNER/REPO/<commit>`, or `?ref=refs/heads/main&rev=<commit>` for a `git+` URL), takes the template-owned files from it and commits with `commit.upgrade_subject` naming `main@<commit>`; everything else is the upgrade of a release. The `framework` row of `dotsteward pins latest` then reports `current` while that commit contains the newest release and `review` once a newer release exists, so `dotsteward-update` moves the instance to the release later.

An instance commit that waits for this fix (a maintain transaction the framework defect blocked, so `HEAD` is ahead of `origin/<branch>`) stays in place through the trial, which runs the instance as it is: its `e2e` (and the recovery's) checks the remote against `origin/<branch>`, an ancestor of `HEAD`, instead of `HEAD` itself. The upgrade then refuses, naming `--carry`:

```bash
dotsteward contribute upgrade --tag <tag> --carry
```

`--carry` saves those commits (as `refs/dotsteward/carry/<run id>` and in the run state), resets the instance to `origin/<branch>`, runs the upgrade, applies the commits again on top of the upgrade commit (their messages and authors kept), then syncs (mirrors that changed are folded into the last carried commit) and runs the gate on the whole tree before `rebuild`, `e2e` and the publish, which ships the upgrade and the carried commits together: the maintain transaction continues on the upgraded framework. A conflict in the generated `.dotsteward` mirrors is resolved by the sync; any other conflict stops the upgrade with the cherry-pick in progress: resolve it in the instance, `git add` the files, run `git cherry-pick --continue` (until it is done), then run the upgrade again. `git cherry-pick --abort` starts the carry over; `abort` names the saved commits. `--carry` works with `--main` as well. A red step leaves its changes uncommitted (or committed but unpublished) and says what to fix, and it runs no recovery after a trial switch (the change is merged, so the trial framework is what `main` has); run the same upgrade again afterwards, it resumes at the instance commit. On a machine that must not switch, `dotsteward contribute upgrade --build-only` rebuilds without switching and skips `e2e`; if a trial had switched the machine, switch it to the upgraded instance afterwards with `dotsteward rebuild --profile <profile> --switch` when the user wants that.
