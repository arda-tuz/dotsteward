# Contributing from your machine

When a change belongs in the framework rather than in your instance, a
defect any user would hit or a feature of the CLI, a catalog component, a
skill or these docs, `dotsteward contribute` carries it from your machine
to a release and upgrades your instance to it. The `dotsteward-contribute`
skill drives the steps; this page describes what each one does.
[CONTRIBUTING.md](../CONTRIBUTING.md) has the rules every change follows,
and [skills.md](skills.md#classification) how a request is classified.

## Modes

| Mode | When | Where the change lands |
| --- | --- | --- |
| fork (default) | always available | your fork of the framework; an upstream pull request only when you ask (`upstream.pr_to_upstream`) |
| owner | `upstream.contribute = "owner"` in `workstation.toml`, a `gh` login with push permission on the upstream, and a local clone whose `origin` is the upstream | the upstream `main`, released by the next release train |

When the conditions of owner mode do not hold, the mode falls back to fork with a
warning, never an error. `dotsteward contribute mode --json` shows the mode
and why. The `[upstream]` table of [workstation-toml.md](workstation-toml.md)
names the fork and the local clone.

## Steps

| Step | Command | What it does |
| --- | --- | --- |
| mode | `dotsteward contribute mode` | Owner or fork, and why. Writes nothing. |
| setup | `dotsteward contribute setup` | Clones or fetches the framework (`upstream.local_clone`), sets the clone's `user.name`, `user.email` (your GitHub noreply address) and `core.hooksPath` (the clone's pre-commit, commit-msg and pre-push hooks). A missing fork is created only with `--create-fork`. |
| start | `dotsteward contribute start --slug SLUG` | Branch `fix/SLUG` from a freshly fetched upstream `main` and a new run; the same slug again resumes its run. `--promote NAME` moves a private component into the catalog (see [The framework gate](#the-framework-gate)). |
| reproduce | `dotsteward contribute check --expect-fail PATH` | Runs the new test, which must fail before the fix. |
| commit | `dotsteward contribute commit -m SUBJECT [--test]` | Stages everything in the clone and commits it with your identity and UTC dates; refuses a subject that is not a conventional commit and any trailer. `--test` marks the reproduction, after it failed. |
| check | `dotsteward contribute check` | The framework gate on a clean clone: privacy scans, then `nix flake check`. |
| trial | `dotsteward contribute trial` | Your instance's gate, `rebuild --switch` and `e2e` with the candidate framework (`--build-only`: gate and build only). |
| publish | `dotsteward contribute publish` | Owner: pull request, lint and privacy CI, fast-forward of `main` to the tested commits. Fork: push, CI, fast-forward of the fork's `main`. |
| release | `dotsteward contribute release` | Once `main`'s CI is green on the merged commit: the tag of the version its release commit set; owner mode also creates the GitHub release with grouped notes. Without a release commit, nothing to release. |
| upgrade | `dotsteward contribute upgrade --tag TAG` | Your instance moves to the release (`--main`: to the merged commit, without a release): lock, gate, commit, rebuild, `e2e`, publish. `--carry` carries unpublished instance commits across it. |
| report | `dotsteward contribute report` | The result: the outcome (`completed`, or `published` for a run that ends right after publish, without a release or an instance commit), pull request, merged commit, release, instance commit, tests and a promoted component. Ends the run. |

`dotsteward contribute status --json` shows the run at any time, and
`dotsteward contribute abort` ends it (see [Recovery](#recovery)). Every
step prints the next command, and a step out of order refuses and names the
right one. While a long step runs, the other steps refuse and `status`
names it; `dotsteward contribute status --wait` waits for it (see
[Run state](#run-state)).

## Reproduce first

Every change starts with a test that fails: an end-to-end or regression
test for a defect, a contract test for a feature. Write it in the clone,
then prove it fails:

```sh
dotsteward contribute check --expect-fail tests/cli/example/test-example.sh
```

Then fix the cause generically: in English, without any value of your own
instance (no user names, paths, private component names or settings).
Never copy instance files into the framework.

Commit the test alone, then the fix, with `dotsteward contribute commit`:
it stages everything and commits with your identity and UTC dates, and it
refuses a subject that is not a conventional commit, trailers and
attribution lines. A plain `git commit` in the clone meets the same rules
in its commit-msg and pre-commit hooks.

```sh
dotsteward contribute commit -m "test(<area>): <what the test expects>" --test
dotsteward contribute commit -m "fix(<area>): <what changed>"
```

## The framework gate

`dotsteward contribute check` runs, in a clean clone of the branch:

1. `dotsteward scan --tree --redact` over the framework tree;
2. a scan of every commit after upstream `main` with the commit metadata
   rules and your private denylist;
3. an **instance-leak scan** of the same commits with terms taken from
   `dotsteward context --json`: your user name and home, the instance
   remote, private component names, settings target and entry names,
   instance skill names and the host name (terms shorter than 4
   characters, allowlisted strings and your public identity are skipped);
4. `nix flake check` with a parallelism of its own (below).

A change that moves one of your private components into the catalog
names that component everywhere. With your explicit approval, start its
run with `dotsteward contribute start --slug SLUG --promote NAME`: the
instance-leak scan of that run exempts exactly the name `NAME` (the run
records it as `promote`, and `check`, `status` and `report` show it),
while every other term, the component's own settings targets included,
still stops the run. The exemption never goes through
`privacy/allowlist.txt` or `privacy/policy.toml`.

Any privacy finding is a hard stop (exit 4): nothing may be published
until the finding is gone from every commit of the branch. A branch that
changes `privacy/allowlist.txt` or `privacy/policy.toml` is refused too;
those files change only in their own, manually reviewed pull request. See
[privacy.md](privacy.md).

The framework's checks are test runs and evaluations, which need less
memory than the instance builds the gate's parallelism is sized for, so
step 4 derives its own from the machine: the budget is the total memory
minus 2048 MiB, as for the gate; one job per full 3072 MiB of it, at most 4
jobs and at most one per CPU; the cores of a job are the CPUs divided among
the jobs, at most one per full 1024 MiB of a job's share. A machine with
16 GiB and 12 CPUs runs 4 jobs on 3 cores each, an 8 GiB machine one job.
`gate.nix_max_jobs` and `gate.nix_cores` do not apply to it.
`DOTSTEWARD_CONTRIBUTE_NIX_MAX_JOBS` and `DOTSTEWARD_CONTRIBUTE_NIX_CORES`
override the values for one run, and `DOTSTEWARD_MEMORY_MIB` and
`DOTSTEWARD_CPU_COUNT` replace the facts of the machine, as they do for
the gate. `contribute check` prints the values it uses.

## Trial

The trial runs your own instance against the candidate framework
(`--framework-override git+file://<clone>?rev=<commit>`): its gate, a
switch to the resulting generation and the end-to-end checks, all run by the
candidate's own CLI (your instance's `dotsteward` package built with that
override), so the candidate's hooks see the library of their own release. A
red trial publishes nothing. `--build-only` stops after the build; publishing then
also requires the clean-install workflow to pass on the commit, which
activates it on a disposable CI machine.

An instance commit that waits for the fix (a maintain transaction the
defect blocked, so `HEAD` is ahead of its remote branch) stays in place:
the trial runs the instance as it is, and its `e2e`, like the recovery's,
checks the remote against the remote branch's commit, an ancestor of
`HEAD`, instead of `HEAD` itself. The upgrade then carries that commit
(`--carry`, below).

## Publish and release

Publish requires that the branch's commit is the one `check` and `trial`
passed, that `VERSION` is the release the commits are based on or the
next release, and that lint and the privacy scans are green on the pull
request (the `lint` job of `ci.yml` and the `generic` job of
`privacy.yml`). In owner mode the upstream `main`
is fast-forwarded to exactly the tested commits, keeping their author,
committer and UTC dates; a merge button on GitHub is never used, because
it writes a new commit with another identity. The merged tree must equal
the tested tree. When upstream `main` moved, the branch is rebased and the
run goes back to `check` (exit 5).

A `git ls-remote`, fetch or push that fails for the network (a connection
that times out, a name that does not resolve, an answer that never comes)
says nothing about the change, so `publish` and `release` make it again
after a pause that starts at `DOTSTEWARD_CONTRIBUTE_POLL_SECONDS` and
doubles, until the failures lasted `DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS`
(the fetch of `check` too, and of `start`, which stops after a minute unless
that variable says otherwise). A
push reads its ref again first, because a push whose answer was lost has
landed. A push the remote refuses (a protected branch, a `main` that moved),
a finding of the pre-push hook, a refused login and a failure on this machine
(no `ssh`) are verdicts, and so are words the CLI does not know as those of a
failed connection: they get one attempt. Over HTTP the failure of a POST ends
`git push` with the status of a rejected push, so the words decide.

The full check (`nix flake check`) runs on every push to `main`, nightly
and for pull requests from forks, not on the pull requests and branches of
the repository itself. `dotsteward contribute status` shows `main`'s CI for
the merged commit (`main_ci`: pending, green or red, with the run's URL).

Releases are trains. `VERSION` keeps the release the commits are based on,
so a fix needs no release of its own, and a run may end right after
publish (`dotsteward contribute report`). A release commit sets `VERSION`
to the next version: `bash tools/version.sh bump` in the clone, with
semantic versioning from the conventional commits since the last release
(any `feat` makes the next minor, anything else the next patch; a breaking
change the next major, only with `--major`, a decision of the user). The
copies of `VERSION` (the plugin manifests, the marketplace and the
`dotsteward` tag of `template/flake.nix`) are written by `bash
tools/version.sh sync`, never by hand. `release` waits until `main`'s CI
(the push runs of `ci.yml` and `privacy.yml`) is green on the merged
commit, then tags it with that version; a missing, red or unfinished run
releases nothing. A read of GitHub that fails during that wait (a dropped
connection, an HTTP 5xx answer) is no CI result: it is made again after a
pause that starts at `DOTSTEWARD_CONTRIBUTE_POLL_SECONDS` and doubles, and
only reads that keep failing for `DOTSTEWARD_CONTRIBUTE_APPEAR_SECONDS`
stop the step. The release workflow (`release.yml`) does the same
without a run once `ci.yml` passed on `main`, or on a dispatch; when it
cut the run's release first, `release` records that tag once `main`'s CI
is green and creates no second one. It often does so while `release`
still waits for that CI, so `release` reads the tag on `origin` again
after the wait (and after a push that failed): a tag on the merged commit
is the run's release, one on another commit stops the step with nothing
changed. The other way round, a GitHub release that `release` created
while the workflow was about to create it is the workflow's release when
its tag names the workflow's commit. There is no changelog file; the
GitHub release lists the commits since the last release under Features,
Fixes and Other.

## Upgrade

`dotsteward contribute upgrade --tag TAG` runs in your instance:
`update prepare --scope maintain`, the `dotsteward` input of `flake.nix`
moved to the tag, `nix flake update dotsteward`, the launcher and
`bootstrap.sh` refreshed from the release's `template/`, `sync`, the gate,
a commit with `commit.upgrade_subject`, `rebuild --switch`, `e2e` and
`update publish --scope maintain`. It is safe to run again; it resumes at
the instance commit.

`--main` moves the instance to the merged commit instead, the one the
run's `check` and `trial` passed for, pinned by its revision on the same
repository URL; a run need not wait for a release. `dotsteward pins latest`
reports such a pin `current` while it contains the newest release and
`review` once a newer one exists.

An unpublished instance commit (a maintain transaction that waits for the
fix) makes the upgrade refuse; `--carry` saves it, resets the instance to
its remote branch, upgrades, applies the commit again on top, syncs and
gates the whole tree, and publishes both. A conflict outside the generated
mirrors stops with the cherry-pick in progress: resolve it, run
`git cherry-pick --continue`, then the upgrade again.

## Run state

Each run has a state file, `<state root>/contribute/<id>.json` (mode
0600), with `id`, `slug`, `mode`, `clone`, `branch`, `base_sha`,
`test_sha`, `tested_tree`, `trial_switched`, `pr`, `merged_sha`, `tag`,
`instance_commit` and `step`, the next step to run (and `promote` in a run
started with `--promote`). Every step reads and updates it, so an
interrupted run resumes where it stopped;
`--id ID` addresses a run other than the current one.

The long steps (`check`, `trial`, `publish`, `release`, `upgrade`, `abort`
and `report`, which may first run the recovery of a trial switch) record
`running` (`step`, `pid`, `started_at`) while they work and
replace it with `last_step` (`step`, `status`, `started_at`, `ended_at`)
when they end, also after a failure or an interrupt. Meanwhile `setup`,
`start`, `commit` and the long steps of every run refuse and name the
running step, and `dotsteward contribute status` shows it. To wait for a
step that runs in the background, without polling the process list:

```sh
dotsteward contribute status --wait --timeout 540
```

It returns when the step ends and exits with the step's status, or with 3
when the timeout passed first (wait again). A marker whose process is gone,
because it was killed or the machine stopped, is stale: `status` and the
next step report and clear it, and its outcome counts as unknown.

| Exit status | Meaning |
| --- | --- |
| 0 | the step is done; the output names the next command |
| 1 | refused or red; nothing was published by this step |
| 3 | still running (`status --wait --timeout`) |
| 4 | privacy hard stop (`check`) |
| 5 | back to `check` (`publish`): the branch was rebased or the merged tree differed |

## Recovery

A full trial switches your machine to the candidate framework
(`trial_switched` is true). If the run then ends without a successful
upgrade, because a step is red, a privacy stop, red CI, your decision or
a `report` that ends the run at publish, the recovery runs `rebuild --switch` and `e2e` without the override, so the
machine and its framework skills return to the pinned release. Red steps
recover on their own, except `release` and `upgrade`: the change is merged
with the tested tree, so the machine keeps the trial framework, which is
what `main` has, until the upgrade switches on; run the red step again once
the cause is fixed. A step that stops because the network kept failing says
so and leaves the machine as it is too: the failure says nothing about the
change, so run the step again once the network is back. `dotsteward contribute abort` recovers
first and then ends the run. Abort never undoes what is already public: a
merged commit stays, and an open pull request stays open until you close
it.
