# Maintain transactions: maintain begin and apply

A maintain transaction changes the instance on purpose: a new component, a removed one, a setting
written to the repository, a pin moved by hand. The `dotsteward-maintain` skill plans and edits; two
commands do every mechanical step in their fixed order.

```sh
dotsteward maintain begin --json                       # open: guards, preflight, base, settings
# ... edit the instance checkout ...
dotsteward apply -m "feat: add example-app" --activate --publish
```

## maintain begin

`dotsteward maintain begin [--profile PROFILE] [--json]` checks that the instance checkout is the top
of a git work tree, on `instance.branch`, with `origin` exactly `instance.remote`. It fetches the
branch and fast-forwards a checkout that is only behind (uncommitted changes stay, git refuses when
they overlap), and refuses a checkout that diverged (the commits of an `apply` that lost the race of
its push are finished by that `apply`, see below). Then it runs `preflight --read-only` for the
profile, `txn prepare --official-sources-only --scope maintain`, which records the base, and
`settings status`. With commits that the remote lacks begin records no base: the remote tip is their
base, and `apply` finishes them with the rest.

`--json` prints one document: `open`, `offline`, `base_oid`, `head_oid`, `instance` (`path`,
`branch`, `remote`), `machine`, `profile`, `activate` and `publish` (the defaults of `apply`),
`dirty`, `unpublished_commits`, `preflight` (the document of the preflight), `settings_pending`,
`warnings` (of `txn prepare`), `ask`, `refused` (why it refused, else null) and `next`; a refusal
prints the document too. Each entry of `ask` is a question for the user before
anything is written:

| Code | Meaning |
| --- | --- |
| `checkout-dirty` | the checkout has changes (`changes`); `apply` commits them all |
| `unpublished-commits` | commits that the remote lacks (`commits`); `apply` publishes them with the transaction |
| `nonconventional-commits` | some of them have a subject that `txn publish` refuses (`commits`, `subjects`); `run` (`git reset --soft` to the tip) keeps their changes as changes of the transaction |
| `settings-local` | settings that changed here and are not in the repository (`entries`) |
| `adaptive-route` | the machine is not on the fast path of the instance; nothing is opened |

Exit status: 0 open and nothing to ask; 1 refused (and nothing moved); 2 usage error; 3 open with
questions, or the adaptive route, which opens nothing; 6 no network, nothing opened.

## apply

`dotsteward apply [-m SUBJECT] [--activate | --no-activate] [--publish | --no-publish]
[--profile PROFILE] [--json]` runs, under the instance lock:

1. **The base.** The remote tip, fetched; without a network the last known one. A checkout behind
   the remote runs `maintain begin` first. Commits here that the remote does not hold on its tip
   (an earlier run lost the race of its push, below) keep the commit they were made on as their
   base, and move onto the tip after the commit. An unpublished commit without a conventional
   subject is refused here, before anything is staged or activated, since `txn publish` would
   refuse it at the end (`nonconventional-commits`).
2. **Stage.** `git add -A`: Nix and the gate see tracked files only. A change needs `-m`, a
   conventional subject of one line (`commit.conventional_types` of `dotsteward context --json`); without one
   apply refuses with exit 2 before it stages anything. A git repository inside the checkout would
   be staged as a gitlink, an empty directory elsewhere: apply refuses it (`nested-repository`) and
   leaves it out of the index. A checkout on the published tip with no
   change has nothing to apply.
3. **Generate.** `dotsteward generate` writes the mirrors of the tree and the derived values of the
   locks, which go into the same commit; nobody runs it by hand before apply. Red, nothing is
   committed (`generate-failed`). A change that only generate made needs `-m` as well.
4. **The gate.** `gate --scope maintain` proves the tree, or answers from its memo of the same tree
   in the same scope. Red, nothing is committed (`gate-failed`, with the log). On a machine that is
   not the producer, a tree that moves a pin of the base or writes the host file of another machine
   is refused before the memo (`writer-class`, [machines.md](machines.md#who-writes-what)).
5. **The commit.** With `SUBJECT` and the trace line of this machine (`Dotsteward-Machine: <name>`,
   [machines.md](machines.md#the-trace-line)), in UTC, never amended. The index must be the tree the
   gate proved, and so must the commit: when a commit hook changed it, apply takes back the commit
   it just made (`reset --soft`, the changes stay staged) and the same command proves the new tree
   (`tree-changed`).
6. **Activated** (`--activate`): an adopt-mode profile never installs a system-level component
   (`deb` and `system` on Linux, `app-archive` on macOS) in its rebuild, so for every such component that the
   transaction adds or changes and that `install --check-only` does not find in place, apply runs
   `install --profile PROFILE --component NAME` first. It needs sudo: on a terminal it runs there;
   without one `install-required` names the command and the run waits (exit 3) until the person ran
   it. Then `rebuild --switch` of the committed tree, unless it is active already, and E2E against
   the base (`--expected-remote-base`), unless E2E with the repository checks already passed for the
   active tree, generation and profile.
7. **Published** (`--publish`): `txn publish --scope maintain`, which after an activation needs that
   passed E2E. It pushes without force and makes sure the remote holds the commit.
8. **State recorded** (after a green publish): what this machine observes goes to its state branch,
   as `dotsteward state record` writes it (`recorded_by` `apply`, [machines.md](machines.md#the-state-of-a-machine)),
   so `dotsteward add` and `dotsteward remove` leave the state of the machine as current as the intent.
   A record that cannot be made (a machine without a name, a finding of the privacy scan, no network for
   its push) is a note in the `state` step and on standard output, never a red run: the commit is
   published, and the next `state record` or `state push` catches up.

## When another machine published first

`txn publish` says so with exit 3 when the remote is no longer at the base, before the push or as a
push rejected as no fast-forward. apply then waits a random moment (up to 2, then 4 seconds) and
moves its commits onto the new tip, never in the checkout:

1. A clone of the checkout under `<state>/apply/replay`, on the tip, with the settings and hooks of
   the checkout, picks the commits after the base one by one (`git cherry-pick`, author, dates and
   trace line kept). No commit goes: one whose change the tip has already stays, empty. A merge
   commit among them is not moved (`replay-merge`, with the command that lines them up).
2. A path both sides changed: a mirror under `.dotsteward/` is taken from the tip. `flake.lock` is
   taken from the tip only when this commit added to its parent's lock and moved no value of it;
   `nix flake lock` then adds the inputs this tree adds and the tip lacks. A moved pin of the lock,
   and any other path, stops
   the replay (`publish-conflict`, with the `paths`): no text is merged, the clone goes, the
   checkout keeps its commits as they were, with no cherry-pick or rebase in it, and the run waits
   (exit 3) for a person to settle it (`run`) and run the same command.
3. `generate` in the clone, and what it changes goes into the top commit, which keeps its message.
4. The checkout moves to the result with `git reset --keep`, and the new tip is the base.
5. The gate proves the new tree, and with `--activate` the rebuild and E2E against the new base run
   again, before the next push. A red step from here on says that the commits moved onto the tip
   and wait here.

A run pushes at most three times. When the remote moved each time, the commits stay here
(`publish-race`) and the same command later moves them onto the tip and publishes them.

`[maintain] activate` and `[maintain] publish` of `workstation.toml` are the defaults; both are
false, so without an option apply gates and commits and the commit waits here. An option wins.

There is no resume command and no journal: every run works out again what is left, as `upgrade`
does. After a red step fix the cause; a fix is a new commit, and the same command proves the new tree
with the gate, activates it and runs E2E again before it pushes. When the cause is in the framework,
`dotsteward-contribute` fixes it, and its `contribute upgrade --carry` keeps the unpublished commits
across the upgrade; then `dotsteward apply` again. Without a network the push waits (exit 6) and the
next run with the network runs E2E with the repository checks before it publishes.

The report is in `<state>/runs/apply/` (and `--json` prints it): every step with its `seconds`, and
in `data` the `base`, the `commit`, the `profile`, the `machine`, `activate`, `publish` and
`published`. What waits or failed is in `review.json`:

| Code | Meaning |
| --- | --- |
| `nonconventional-commits` | unpublished commits whose subject `txn publish` refuses; `run` folds them into the change |
| `nested-repository` | git repositories inside the checkout (`paths`); vendor their files or remove them |
| `generate-failed` | `dotsteward generate` failed; nothing was committed |
| `gate-failed` | the gate refused the tree, or could not judge it (`environment`); nothing was committed |
| `writer-class` | the tree changes what this machine does not write (`paths`, the `producer`; `run` makes this machine the producer); nothing was committed |
| `commit-refused` | git or a hook refused the commit |
| `tree-changed` | the tree to commit is not the tree the gate proved (a commit hook changed it); nothing was committed |
| `install-required` | system-level components wait for `run` in a terminal (pending) |
| `install-failed` | their install failed |
| `rebuild-failed` | the rebuild failed; the commit stays here |
| `e2e-red` | E2E is red (`findings`); nothing was published |
| `e2e-no-result` | E2E ended without a result |
| `publish-conflict` | another machine changed the same lines (`paths`) on the tip (`tip`); `run` takes the remote in with `git pull --rebase origin <branch>`, also without an upstream branch, for a person to settle, and runs the same apply (pending) |
| `publish-race` | the remote moved before each of three pushes (another machine, or a skill capture of this one); the same command (`run`) moves the commits onto the new tip (pending) |
| `replay-merge` | a merge commit among the commits (`commits`); `run` lines them up on the tip and runs the same apply (pending) |
| `replay-failed` | the commits could not move onto the tip for another reason (the message says which) |
| `publish-refused` | `txn publish` or the remote refused |

Exit status: 0 done; 1 a refusal or a red step; 2 usage error; 3 a sudo step or a person waits (a
conflict with the remote, a remote that kept moving); 6 no network, the push waits; 130 interrupted,
the same command goes on.
