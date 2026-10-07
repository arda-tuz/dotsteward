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
| owner | `upstream.contribute = "owner"` in `workstation.toml`, a `gh` login with push permission on the upstream, and a local clone whose `origin` is the upstream | the upstream `main`, followed by a patch release |

When the owner conditions do not hold, the mode falls back to fork with a
warning, never an error. `dotsteward contribute mode --json` shows the mode
and why. The `[upstream]` table of [workstation-toml.md](workstation-toml.md)
names the fork and the local clone.

## Steps

| Step | Command | What it does |
| --- | --- | --- |
| mode | `dotsteward contribute mode` | Owner or fork, and why. Writes nothing. |
| setup | `dotsteward contribute setup` | Clones or fetches the framework (`upstream.local_clone`), sets the clone's `user.name`, `user.email` (your GitHub noreply address) and `core.hooksPath`. A missing fork is created only with `--create-fork`. |
| start | `dotsteward contribute start --slug SLUG` | Branch `fix/SLUG` from a freshly fetched upstream `main` and a new run; the same slug again resumes its run. |
| reproduce | `dotsteward contribute check --expect-fail PATH` | Runs the new test, which must fail before the fix. |
| check | `dotsteward contribute check` | The framework gate on a clean clone: privacy scans, then `nix flake check`. |
| trial | `dotsteward contribute trial` | Your instance's gate, `rebuild --switch` and `e2e` with the candidate framework (`--build-only`: gate and build only). |
| publish | `dotsteward contribute publish` | Owner: pull request, CI, fast-forward of `main` to the tested commits. Fork: push, CI, fast-forward of the fork's `main`. |
| release | `dotsteward contribute release` | The next patch tag on the merged commit; owner mode also creates the GitHub release with generated notes. |
| upgrade | `dotsteward contribute upgrade --tag TAG` | Your instance moves to the release: lock, gate, commit, rebuild, `e2e`, publish. |
| report | `dotsteward contribute report` | The result: pull request, merged commit, release, instance commit, tests. Ends the run. |

`dotsteward contribute status --json` shows the run at any time, and
`dotsteward contribute abort` ends it (see [Recovery](#recovery)). Every
step prints the next command, and a step out of order refuses and names the
right one.

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
4. `nix flake check` with the gate's parallelism.

Any privacy finding is a hard stop (exit 4): nothing may be published
until the finding is gone from every commit of the branch. A branch that
changes `privacy/allowlist.txt` or `privacy/policy.toml` is refused too;
those files change only in their own, manually reviewed pull request. See
[privacy.md](privacy.md).

## Trial

The trial runs your own instance against the candidate framework
(`--framework-override git+file://<clone>?rev=<commit>`): its gate, a
switch to the resulting generation and the end-to-end checks. A red trial
publishes nothing. `--build-only` stops after the build; publishing then
also requires the clean-install workflow to pass on the commit, which
activates it on a disposable CI machine.

## Publish and release

Publish requires that the branch's commit is the one `check` and `trial`
passed, that `VERSION` equals the next release, and that CI is green. In
owner mode the upstream `main` is fast-forwarded to exactly the tested
commits, keeping their author, committer and UTC dates; a merge button on
GitHub is never used, because it writes a new commit with another identity.
The merged tree must equal the tested tree. When upstream `main` moved, the
branch is rebased and the run goes back to `check` (exit 5).

`release` tags the merged commit with the next patch version (`v0.0.1`
when there is no tag yet). There is no changelog file; the release notes
are generated from the commits.

## Upgrade

`dotsteward contribute upgrade --tag TAG` runs in your instance:
`update prepare --scope maintain`, the `dotsteward` input of `flake.nix`
moved to the tag, `nix flake update dotsteward`, the launcher and
`bootstrap.sh` refreshed from the release's `template/`, `sync`, the gate,
a commit with `commit.upgrade_subject`, `rebuild --switch`, `e2e` and
`update publish --scope maintain`. It is safe to run again; it resumes at
the instance commit.

## Run state

Each run has a state file, `<state root>/contribute/<id>.json` (mode
0600), with `id`, `slug`, `mode`, `clone`, `branch`, `base_sha`,
`test_sha`, `tested_tree`, `trial_switched`, `pr`, `merged_sha`, `tag`,
`instance_commit` and `step`, the next step to run. Every step reads and
updates it, so an interrupted run resumes where it stopped;
`--id ID` addresses a run other than the current one.

| Exit status | Meaning |
| --- | --- |
| 0 | the step is done; the output names the next command |
| 1 | refused or red; nothing was published by this step |
| 4 | privacy hard stop (`check`) |
| 5 | back to `check` (`publish`): the branch was rebased or the merged tree differed |

## Recovery

A full trial switches your machine to the candidate framework
(`trial_switched` is true). If the run then ends without a successful
upgrade, because a step is red, a privacy stop, red CI or your decision,
the recovery runs `rebuild --switch` and `e2e` without the override, so the
machine and its framework skills return to the pinned release. Red steps
recover on their own; `dotsteward contribute abort` recovers first and then
ends the run. Abort never undoes what is already public: a merged commit
stays, and an open pull request stays open until you close it.
