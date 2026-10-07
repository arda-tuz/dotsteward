# Publish, release and upgrade

What `dotsteward contribute publish`, `release` and `upgrade` do in each mode, what they refuse, and what the skill does next. The commands print the next step on every refusal; follow it.

## Preconditions of publish

- The run passed `check` (the framework gate) and `trial` for the current commit of the branch: the clone is clean, on the run's branch, at the checked commit. A new commit after the gate means `check` and `trial` again.
- `VERSION` of the checked commit equals the next release tag (`references/framework-change.md`), checked before anything is pushed and again before the merge.
- `gh` is installed and logged in (`gh auth login` otherwise).
- After a build-only trial, the `clean-install.yml` workflow must also be green on the checked commit; publish dispatches it on the branch when it has not run. If GitHub Actions are disabled on the target repository, run a full trial instead.

## Owner mode

1. Pushes `fix/<slug>` to the upstream (the pre-push hook scans the pushed commits and tree with the denylist).
2. Opens the pull request, or reuses the open one of the branch.
3. Waits for every CI check of the pull request to finish. Red CI: `main` is untouched; read the failing job (`gh run view --log-failed`), fix the cause in a new commit, then `check`, `trial` and `publish` again.
4. Requires the branch to be up to date with the upstream `main`. If `main` moved, publish rebases the branch onto it and exits 5: the run is back at `check` (the rebased commit has not been tested). A rebase conflict is left for you to resolve in the clone; then run `check`.
5. Merges by pushing the checked commit to the upstream `main`, which fast-forwards the upstream `main` to exactly the commits that passed the gate, with their author, committer and UTC dates; GitHub then records the pull request as merged. Never merge the pull request on GitHub (squash, merge or rebase button): GitHub writes a new commit with the account's display name and local time, which the privacy scans refuse on `main`. If `main` moved at the last moment, the push no longer fast-forwards: publish rebases the branch as in step 4 and exits 5. A push the upstream refuses (for example a protected branch) is red and `main` is untouched.
6. Verifies that the merged commit on `main` has exactly the tested tree. A pull request merged on GitHub by hand with other changes releases nothing: the branch is put on the merged `main`, publish exits 5, and the run goes back to `check`, which then checks the merged commit itself.

A closed pull request stops the run: reopen it, or end the run with `dotsteward contribute abort`.

## Fork mode

1. Pushes `fix/<slug>` to the fork and waits for the fork's CI on the checked commit.
2. Fast-forwards the fork's `main` to the checked commit and verifies that it has the tested tree (a mismatch stops the run red; nothing is released). If the fork's `main` has commits the branch lacks, merge them into the fork's `main` by hand first.
3. Opens a pull request to the upstream only when `upstream.pr_to_upstream` is true in `workstation.toml` or the user asks for it; ask before opening one on someone else's repository:

   ```bash
   dotsteward contribute publish --pr-to-upstream
   ```

The release is then a tag on the fork, and the instance upgrades to the fork's tag until the upstream ships the change.

## Release

`dotsteward contribute release` creates the next patch tag (newest `v*` tag plus one, `v0.0.1` when there is none) as an annotated tag on the merged commit and pushes it. In owner mode it also creates the GitHub release with generated notes (`gh release create --generate-notes --verify-tag`). It refuses when `VERSION` of the merged commit is not that version, or when the tag already exists elsewhere. It is safe to rerun: an existing tag on the merged commit is kept.

## Upgrade

`dotsteward contribute upgrade --tag <tag>` runs in the instance checkout, which must have no uncommitted changes:

1. `update prepare --scope maintain` (the instance `HEAD` must equal its remote branch; `git pull --ff-only` when it is behind),
2. the `dotsteward` input of `flake.nix` moved to the tag, then `nix flake update dotsteward`,
3. `bootstrap.sh` and `.dotsteward/cli.sh` refreshed from the release's `template/`, then `sync`,
4. the instance gate, then a commit with `commit.upgrade_subject` of the context,
5. `rebuild --switch` and `e2e` (no override), then `update publish --scope maintain`.

Once `flake.lock` pins the release, `sync`, the gate, the rebuild, `e2e` and the publish run through the instance launcher (`.dotsteward/cli.sh`), so the release's own CLI validates the upgraded instance. A red step leaves its changes uncommitted (or committed but unpublished) and says what to fix; run the same upgrade again afterwards, it resumes at the instance commit. On a machine that must not switch, `dotsteward contribute upgrade --build-only` rebuilds without switching and skips `e2e`; if a trial had switched the machine, switch it to the upgraded instance afterwards with `dotsteward rebuild --profile <profile> --switch` when the user wants that.
