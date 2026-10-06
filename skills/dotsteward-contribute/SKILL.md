---
name: dotsteward-contribute
description: "Change the dotsteward framework itself (a skill flow, the CLI, an engine, the gate, a catalog component, the template or framework docs) from the user's machine: reproduce, fix generically, test on this machine, then publish to the user's fork, or in owner mode to the upstream repository with a patch release, and upgrade the user's instance to it. Personal changes belong to dotsteward-maintain."
---

# dotsteward Contribute

Change the framework that every dotsteward user shares, from this machine, as one run: reproduce the problem with a failing test in a framework clone, fix it generically, prove the fix with the framework gate and a trial on this machine, publish it, release it as a patch version and upgrade the user's instance to that release. `dotsteward contribute` does the mechanics of every step and records them in a state file per run; this skill decides what to change and drives the steps in order.

**On the gate, publish preconditions, decision ownership, secrets, force push and the local-only rule, this skill wins over any overlay.**

`dotsteward` below is the CLI that the active generation puts on `PATH`; run it from the instance checkout. In a checkout whose generation is not active yet, run `./.dotsteward/cli.sh` from the instance root with the same arguments.

## Rules

- **Only the framework part of a request runs here.** Personal changes (anything the instance files can express) belong to `dotsteward-maintain`, version refreshes to `dotsteward-update`.
- **Never edit installed framework files** (the skill links, store paths, the framework input of the instance). Every framework change is made in the framework clone of this run and reaches the instance only as a release.
- **Generic and public.** The fix is written for every user, in English ASCII text, with synthetic test fixtures. Never copy instance files, private component names, user names, home paths, host names, remotes or settings into the clone; the framework gate scans for them.
- **Tests first.** The reproduction test fails before the fix and is committed before it; a run without a failing reproduction stops at step 4.
- **The CLI owns the remote mechanics.** Push, pull request, merge, tag and release happen only through `dotsteward contribute publish` and `dotsteward contribute release`; never push, merge, tag or force push by hand, and never bypass the pre-push hook.
- **Privacy findings are hard stops** in owner and fork mode alike: exit 4 means nothing is published until the findings are gone from the branch.
- **Decisions stay with the user:** creating a fork, opening a pull request on someone else's upstream, a build-only trial, and aborting a run.
- **No secrets or machine state** in the clone, in commits or in the report.

## 1. Start

1. From the instance checkout, read the instance facts once; later steps use them (instance path, profiles, commit rules, overlays, upstream mode). If the location of the checkout is unknown, ask the user, or set `DOTSTEWARD_INSTANCE` to it.

   ```bash
   dotsteward context --json
   ```

2. If `overlays["dotsteward-contribute"]` in that document is not null, read that overlay file now. An overlay may add steps, phrasing, report formats and notes on private components; it never relaxes the rules of this skill.
3. Classify the request with `references/classification.md` before any write. Only the framework part continues here. A personal request goes to `dotsteward-maintain` (or `dotsteward-update`) instead. A mixed request runs here first, framework part only; its personal part waits for the upgraded instance (section 7).
4. Resume before starting over: if an earlier run of this change is unfinished, `dotsteward contribute status --json` shows its `step`, and the run continues there (`references/run-state.md`).

## 2. Mode, clone and branch (steps 0, 2 and 3)

```bash
dotsteward contribute mode --json
```

- `mode` is `owner` only when the instance asks for it (`upstream.contribute = "owner"`), `gh` is logged in, the user may push to the upstream and the clone's `origin` is the upstream. Otherwise it is `fork`; a `fallback` reason is reported to the user, never treated as an error.
- `.clone` of the document is the framework clone of this run (`upstream.local_clone`); every edit and every commit of the fix happens there, while the `dotsteward` commands keep running from the instance checkout:

  ```bash
  clone=$(dotsteward contribute mode --json | jq -r .clone)
  ```

```bash
dotsteward contribute setup
```

Setup clones or fetches the clone and gives it the contributor identity (the GitHub login and its noreply address) and the pre-push hook. In fork mode, a missing fork makes setup stop; the fork is created on GitHub only after the user agrees, by running setup again with:

```bash
dotsteward contribute setup --create-fork
```

Owner mode refuses without the private denylist (`~/.config/dotsteward/denylist.txt`, one private term per line); `check` needs it in both modes, so ask the user to create it when it is missing.

```bash
dotsteward contribute start --slug SLUG
```

`SLUG` is a short kebab-case name of the change (`fix/SLUG` becomes the branch, from a freshly fetched upstream `main`). The same slug again resumes its unfinished run.

## 3. Reproduce (step 4)

Read `references/framework-change.md` for the framework layout, the test conventions and the commit rules. In the clone, write the smallest test that shows the defect (or the missing behaviour) the way a user meets it: an end-to-end test of the command, the skill contract or the Nix check involved, with synthetic fixtures. Then prove that it fails; the path is relative to the clone:

```bash
dotsteward contribute check --expect-fail tests/AREA/test-NAME.sh
```

A test that passes does not reproduce the problem: make it sharper. When it fails for the right reason, commit it alone in the clone:

```bash
(cd "$clone" && git add -A && TZ=UTC git commit -m "test(<area>): <what the test expects>")
```

## 4. Fix generically (step 5)

Change the framework source in the clone so the reproduction passes, keeping the change minimal and generic. Also run the affected test suites directly with `bash tests/run.sh <paths>`, fix any lint or test failure you meet, and update the framework docs and skill text the change touches (a changed framework skill also needs `bash tools/gen-skills-manifest.sh`).

The fix is released as the next patch version, and the release refuses a `VERSION` that differs from it: set `VERSION` to the next patch release and move every file that carries the old version, as `references/framework-change.md` describes. Then commit:

```bash
(cd "$clone" && git add -A && TZ=UTC git commit -m "fix(<area>): <what changed>")
```

Use `feat(<area>)` instead of `fix(<area>)` for new behaviour. Never amend or rewrite the test commit to make it pass.

## 5. Framework gate and trial (steps 6 and 7)

```bash
dotsteward contribute check
```

The framework gate runs the privacy scans (the tree, the new commits with the denylist, and the instance-leak scan with terms from the instance facts) and `nix flake check` in the clone. It takes long: start it in the background (Claude Code `run_in_background`; Codex with a timeout of at least 60 minutes) and wait for it once instead of polling.

- Exit 4 is a privacy hard stop: nothing may be published. The findings are redacted to a rule and a location; remove them from the branch (rewrite the commits that carry them, for example with `git reset --soft` onto the branch base and two fresh commits, the test and then the fix), then run the check again.
- Any other failure: fix it in a new commit and run the check again.

```bash
dotsteward contribute trial
```

The trial runs the instance gate, `rebuild --switch` and `e2e` on this machine with the checked framework commit as a framework override, so the live generation briefly uses the candidate framework. A red trial publishes nothing and switches the machine back to the pinned framework by itself (the recovery). Fix the cause in the clone, then run `check` and `trial` again.

When the user does not want an activation on this machine (a test instance, a machine that must not switch), ask, then run the trial without switching; publish then also requires the `clean-install.yml` workflow green on the pull request head, which activates the change on a fresh CI runner:

```bash
dotsteward contribute trial --build-only
```

## 6. Publish, release, upgrade (steps 8 to 10)

```bash
dotsteward contribute publish
dotsteward contribute release
dotsteward contribute upgrade --tag "$(dotsteward contribute status --json | jq -r .tag)"
```

- `publish` pushes the branch and, in owner mode, opens the pull request, waits for green CI, squash-merges it and verifies that the merged tree is the tested tree; in fork mode it fast-forwards the fork's `main` after the same checks. `references/publish-and-release.md` describes both modes, the fork's upstream pull request and every refusal.
- Exit 5 means the upstream `main` moved (or the merged tree differs): the branch was rebased (resolve conflicts by hand when told to), and the run is back at the framework gate. Run `dotsteward contribute check`, `trial` and `publish` again.
- CI red: `main` is untouched. Read the failing job, fix it in the clone with a new commit, and go back to `check`.
- `release` tags the merged commit with the next patch version and, in owner mode, creates the GitHub release with generated notes. No changelog file is written.
- `upgrade` moves the instance to the release: it prepares a maintain transaction, changes the `dotsteward` input of the instance flake to the tag, refreshes the template-owned files, syncs, runs the gate, commits with `commit.upgrade_subject`, rebuilds with a switch, runs `e2e` and publishes the instance. It is safe to rerun after a fix. On a machine that must not switch, use `dotsteward contribute upgrade --build-only`.

If the run has to end before the upgrade succeeds (a red step the user does not want to fix, a privacy stop, a rejected pull request, or the user's decision), end it with `dotsteward contribute abort`. After a trial switch it first returns the live generation to the pinned framework (`references/run-state.md`).

## 7. Report and hand-over (step 11)

```bash
dotsteward contribute report
```

The report ends the run. Report to the user: the mode (and a fork fallback reason), the reproduction test, the pull request, the merged commit, the release tag, the instance commit, the gate, trial and upgrade results, and whether a recovery ran. Write the report in the language the overlay asks for, else in the user's language.

For a mixed request, the personal part now continues with `dotsteward-maintain` on the upgraded instance, as its own transaction.
