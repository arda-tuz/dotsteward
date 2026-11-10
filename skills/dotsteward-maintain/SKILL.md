---
name: dotsteward-maintain
description: Add, remove, replace, reconfigure, migrate or selectively update components (applications, CLIs, agent skills, application settings, portable state) in the user's dotsteward instance repository so they reproduce on a fresh machine, optionally activate them on this machine, write locally changed application settings to the repository, or track and untrack such a setting. Do not use for changes meant only for this machine; use dotsteward-update for full version refreshes and dotsteward-contribute for changes to the framework itself.
---

# dotsteward Maintain

Maintain one system: this machine is the observed input, the instance checkout is the reviewed source of truth, and a fresh supported machine is the reproduction target. Treat every request as one transaction that may combine many additions, removals, replacements, migrations, reconfigurations and selected version changes; publish only the complete, validated combination.

**On the gate, publish preconditions, decision ownership, secrets, force push and the local-only rule, this skill wins over any overlay.**

`dotsteward` below is the CLI that the active generation puts on `PATH`. In a checkout whose generation is not active yet, run `./.dotsteward/cli.sh` from the instance root with the same arguments.

## Rules

- **Local-only requests stay local.** If the user wants a change only on this machine, or the component is not managed by the instance, make the local change without touching the repository and stop. Ask when it is unclear.
- **Work in the instance checkout on its branch** (`instance.branch` of the context, normally `main`). Never `git stash`, never stage unrelated files, never amend a commit after validation.
- **One gate, run once per final tree,** by `dotsteward apply` (section 4): `dotsteward gate --scope maintain` runs the preflight, the static checks (privacy scan included), the pins check, one `nix flake check` and the CLI probes of the candidate generation, and answers from its memo for an unchanged tree. Never run `dotsteward static`, `dotsteward pins check`, `nix flake check` or profile builds separately. Start `apply` in the background (Claude Code `run_in_background`; Codex with a timeout of at least 45 minutes) and wait for it once instead of polling.
- **Stage before Nix** (`git add -A`, which `apply` does): flakes ignore untracked files, and the gate refuses them. A Nix command you run by hand before `apply` (`nix flake lock`, `dotsteward generate`) needs new files staged first.
- **Bound the network** with `timeout 60` on every command you run by hand that reaches the network. If the binary cache (`gate.cache_url`) is unreachable, stop and report; never use mirrors or extra substituters.
- **Read narrowly.** Read `references/framework-map.md`, then only what it lists for the affected components: their `maintenance.md` and `README.md` in the framework source, the instance files they touch, and the overlay. Use `git grep -n` for everything else.
- **Protected and generated files.** The paths under `protected` in the context are byte-protected. Never hand-edit `flake.lock` (change inputs with `nix flake lock` or `nix flake update <input>`), the `.dotsteward/` mirrors, `bootstrap.sh` or `.dotsteward/cli.sh` (framework-owned bytes). Versions live in `versions.lock.json`; `apply` runs `dotsteward generate`, which writes the mirrors and the derived lock values into the same commit.
- **Who writes what.** With several machines and a producer (`[hosts] producer`), only the producer moves a value that comes from upstream: on any other machine never change a pin the base has (`versions.lock.json`, `flake.lock`, the tool tables and the third-party entries of the skill lock, the files of a third-party skill) or the host file of another machine. A new component may add its first pins, and `machines` is intent. The gate refuses anything else with `writer-class`; the producer moves the rest later.
- **No secrets or machine state in Git:** credentials, tokens, sessions, caches, histories, databases, sockets, logs, machine identifiers and project indexes stay out.
- **Settings files only through the buffer.** Application settings files that the application writes itself are never linked or replaced. Only the entries of the settings buffer (`settings.buffer_dir` of the context) are synchronized, by `dotsteward settings` (`references/local-maintained-files.md`). This skill is the only one that writes the buffer; decisions on conflicts and deletions are always the user's.
- **Framework files are read-only.** Never edit installed framework files (the skill links, the store paths, the framework input); framework changes go through `dotsteward-contribute`.
- **Durable lessons live in versioned text, never in agent memory.** A lesson worth keeping for later runs (an ordering, a machine constraint, the user's preference about this workflow) goes where every agent on every machine reads it: a generic one into the framework skill through `dotsteward-contribute`, an instance-specific one into this skill's overlay as part of the transaction. Never record it in an agent's own memory store, which is per machine, unreviewed and invisible to the other agents.

## 1. Start

1. From the instance checkout, read the instance facts once; later steps use them (paths, profiles, commit rules, overlays, components, settings ids). If the location of the checkout is unknown, ask the user, or set `DOTSTEWARD_INSTANCE` to it.

   ```bash
   dotsteward context --json
   ```

2. If `overlays["dotsteward-maintain"]` in that document is not null, read that overlay file now. An overlay may add steps, phrasing, report formats and notes on private components; it never relaxes the rules of this skill.
3. Classify the request with `references/classification.md` before any write. Personal requests continue here. Framework requests go to `dotsteward-contribute`. Mixed requests go to `dotsteward-contribute` first, which ends with an upgrade of the instance to the new framework release; the personal part then continues here on the upgraded instance.
4. Open the transaction from the instance checkout. One command checks that this is the instance checkout on its branch, fast-forwards it when it is only behind the remote, runs the read-only preflight of the current profile, records the base with `txn prepare --scope maintain` and reads the settings status:

   ```bash
   cd "$(dotsteward context --json | jq -r .instance.path)"
   dotsteward maintain begin --json
   ```

- Exit 1 is a refusal: not the instance checkout, a checkout that diverged from the remote (commits of an earlier `apply` that lost the race of its push: run that `apply` again, which moves them onto the tip), a failed preflight. Stop, report its message and ask.
- Exit 3 means questions in `ask`; put each to the user before writing any tracked file. `checkout-dirty`: do those changes belong to this transaction (`apply` commits them all)? `unpublished-commits`: do those commits belong to it (`apply` publishes them with it)? `settings-local`: write those local settings in this transaction (next section)? `adaptive-route` opens nothing (`open` is false): report the reasons from the `preflight` document, write no tracked file, and ask how to proceed.
- `nonconventional-commits`, from begin or apply: some unpublished commits have a subject that the publish step refuses, so apply refuses them. With the user's agreement run the command in its run field, a soft reset to the tip that keeps every change staged, then give the transaction one subject that the publish step accepts.
- Exit 6: no network; report it and ask.
- `warnings`: an unreachable binary cache means stop and report; `gh` not logged in means ask the user to run `gh auth login`; low disk space is only reported (the gate stops below `gate.min_free_gib` GiB). Never collect garbage or delete Home Manager generations without the user's explicit approval.
- `activate` and `publish` are the defaults of `apply` on this instance (`[maintain]` of `workstation.toml`).

## Track or stop tracking one component

When the request is to track one piece of software (an application, a CLI, a package) or to stop tracking one, and nothing else belongs to the transaction, one command replaces step 4 above and sections 2 to 4: it opens the transaction itself, writes the intent and runs the one `dotsteward apply`, with the same options and the same exit statuses. Run it in the background like `apply`, and choose `--activate` and `--publish` by the rules of section 4.

```bash
dotsteward status
dotsteward add NAME --activate --publish
dotsteward add NAME --apt PACKAGE --command COMMAND --activate --publish
dotsteward add NAME --nix ATTRIBUTE --command COMMAND --activate --publish
dotsteward remove NAME --activate --publish
```

- `dotsteward status` is the read-only, offline overview: what is tracked, what applies on this machine and why not, holds, whether the active generation is the checkout, what other machines brought, the skills and plugins. Read it to plan and to report; it never changes anything.
- NAME is a catalog component or a component of the instance (`components/NAME/default.nix`); plain APT packages that a source of this machine offers take `--apt`, a nixpkgs package takes `--nix`. Scope it with `--here` (only this machine), `--machines`, `--tags` or `--profiles` when the user says so.
- `channel-unknown`: the channel needs research (an official binary, a vendor APT repository, a release download, a Python application). Plan and implement it by sections 2 and 3, writing `components/NAME/default.nix` and its pins, without touching the table, then run the same `dotsteward add NAME` with the same options: it enables the component and commits its files with the table.
- A red gate whose pins check names pins the lock lacks (a catalog component with a download pin): add those first pins by section 3 and the update references, then the same `dotsteward add NAME`.
- `dotsteward remove` keeps the software installed: an APT package, an official binary or a Python environment stays on the machine (a `nix` component leaves the profile at the next activation, which is how Home Manager works; say so). Pass `--uninstall` only when the user asks to remove the software too. `uninstall-required`: ask the user to run the `run` command in their own terminal (it needs `sudo`), or run the same `dotsteward remove NAME --uninstall` on a terminal.
- A question of `maintain begin` (`checkout-dirty`, `unpublished-commits`) means other changes wait: put it to the user as in section 1; the command wrote nothing. A red step or a sudo step is section 5, and the same command finishes it.

## Locally maintained settings

When the user wants local settings written to the repository, or accepts pending entries found at the start, follow the "Write local settings to the repository" workflow in `references/local-maintained-files.md`: `status --json`, a decision report for every entry that needs a decision, `resolve` per the user's answer, `flush`, then the usual `dotsteward apply`, and finally `reconcile`. The decision report is plain text by default; an overlay may ask for another format. Tracking or untracking a setting is a normal transaction with `track`, `track-file` or `untrack`.

## 2. Plan the transaction

- Enumerate every operation, order them by dependency, and find the shared files, so that locks, components, tests and docs describe the final combined state.
- Map each component to its surfaces with `references/framework-map.md` and `references/component-contract.md`: a catalog component configured in `workstation.toml`, a private component under `components/<name>/`, plain Home Manager configuration in `home.nix`, a vendored instance skill, a settings buffer entry, host-only state, a removal or a replacement. `references/integration-contract.md` lists what each integration must prove.
- Research primary sources: license, platforms and architectures, runtime dependencies, update behaviour, configuration locations and secret-bearing state.
- For version changes apply the update policy and hash techniques of `../dotsteward-update/references/update-contract.md` and `../dotsteward-update/references/sources-and-hashes.md`. The pins engine lists the official candidates in seconds:

  ```bash
  dotsteward pins latest
  ```

## 3. Implement the smallest complete slice

Update every affected layer, following `references/integration-contract.md`:

1. the installation: `[components.<name>]` in `workstation.toml` for a catalog component (`enable`, `method` or `method_by_platform`, `profiles`, `options`), `components/<name>/default.nix` (and `package.nix` for an instance package) for a private one, `home.nix` for plain Home Manager configuration;
2. the pins in `versions.lock.json` at the lock paths the component's rules read (and `flake.nix` plus `nix flake lock` for a new flake input); `apply` regenerates the `.dotsteward/` mirrors and the derived lock values with `dotsteward generate`;
3. an idempotent installer: the framework methods (`nix`, `official-binary`, `pypi`, `deb`, `app-archive`, `external`) already are; a component hook script must be safe to rerun and honour `DOTSTEWARD_CHECK_ONLY=1`, and `dotsteward install --profile <profile> --check-only` must pass;
4. a static assertion (an instance script in `[gate] static`, or a component check) and a real smoke or E2E check (`checks.commands`, `checks.e2e`, `probes`);
5. backup, adoption and rollback coverage when a user file is replaced (`bootstrap.backupPaths`, `rebuild.adoptPaths`, `rollback.managedLinks`, `rollback.forceLinkedRestore`);
6. the instance `README.md`, `AGENTS.md` and focused docs (policy, not version numbers);
7. the update allowlist, through the component's `gate.updatePaths` or `[gate] update_allowlist`, when version updates may need to touch the new paths; it never matches the settings buffer;
8. the removal of every stale reference when replacing a component.

New tracked files follow the new-file checklist in `references/framework-map.md`. For a new instance skill, vendor the complete directory under `agent/skills/<name>/` (`[skills] vendor_dir`): `SKILL.md`, `agents/openai.yaml`, a license, and only `references/`, `scripts/` and `assets/` besides. Add its entry to `agent/skills.lock.json` (`[skills] lock`); a skill only some agents need (for example because the others load it from a plugin) also gets `agents`, the agent names of the manifest's `skill_layout.agent_roots`. Then refresh its digests:

```bash
dotsteward pins sync --skill NAME
```

`dotsteward agents install` (run by the rebuild) installs it into the canonical skill root and creates the per-agent links. When a vendored third-party file trips a generic secret rule or a forbidden-path glob without holding a secret, review each finding and record it as a `[[privacy.exemptions]]` entry bound to the file's SHA-256 (with the reason); never exempt a denylist term, and never edit the vendored text to dodge a rule. Framework skills (`dotsteward-*`) never go into the skills lock.

## 4. Validate, commit, activate, verify, publish

One command does every mechanical step, in a fixed order, under the instance lock:

```bash
dotsteward apply -m "<type>: <summary>" --activate --publish
```

- It stages every change (`git add -A`), runs `dotsteward generate`, runs the one gate `dotsteward gate --scope maintain`, commits with the subject and the trace line of this machine, then with `--activate` runs `dotsteward rebuild --profile <profile> --switch` and `dotsteward e2e` against the base, and with `--publish` runs `dotsteward txn publish --scope maintain`. The rebuild and E2E use the committed tree; the publish step refuses a tree that is active on this machine until E2E passed for it, checks the validated tree, the remote base and the commit subjects, pushes without force and verifies the remote OID.
- Pass `--activate` only when local activation is requested or clearly expected, and `--publish` only when the user wants the remote updated; an option you leave out takes `activate` or `publish` of the begin document. Without activation the commit is published without E2E only when the user asks for exactly that.
- Use a conventional commit subject (`feat`, `fix`, `perf`, `refactor`, `docs`, `chore`, `test`, `build`, `ci`, `style`, `revert`; the list is `commit.conventional_types` of the context); any other subject is refused with exit 2 before anything is staged.
- Also exercise the changed component through one real user-facing path when the gate does not (for example an isolated CLI workflow), not only `--version`.
- Exit 0 is done. Exit 1 is a refusal or a red step, exit 3 a sudo step that waits, exit 6 no network (the push waits): `review.json` and the run report (`dotsteward apply --json`) name the step, and the same command goes on from there once the cause is gone. Never `git commit`, `rebuild`, `e2e` or `txn publish` by hand in between.

## 5. When a step is red or waits

- A red gate commits nothing: fix the tree and run the same `apply`. A red rebuild leaves the commit here and runs no E2E.
- If E2E fails, fix it, then run `dotsteward apply -m "fix: <summary>"` with the same options: a new commit (no amend), the gate again, the rebuild with `--switch` (E2E verifies the activated generation, not the commit), then E2E again, and only then the push. A failed check means no push. When the cause lies in the framework (a catalog component, an engine, a hook), the fix goes through `dotsteward-contribute`; its `contribute upgrade --carry` carries the unpublished commits of this transaction across the upgrade, and afterwards `dotsteward apply` with the same options finishes them.
- If the rebuild warns that the login shell is still on a versioned Nix path, ask the user to run the same rebuild once in a terminal; moving the login shell needs `sudo`.
- **Adopt-mode profiles do not install system-level components.** The rebuild of a profile in `adopt` mode never installs a component whose method is system-level (`deb` on Linux, `app-archive` on macOS), so `apply --activate` installs each one that the transaction adds or changes and that is not in place yet, after the commit and before the rebuild. On a terminal it runs the install there, which asks for `sudo`. Without a terminal it stops with exit 3 and an `install-required` item whose `run` is the exact command, `dotsteward --instance <instance.path> install --profile <profile> --component <name>`: ask the user to run it in their own terminal, since it needs `sudo` (their terminal need not be in the instance checkout), then run the same `apply` again. Without it the rebuild would stop at the command probe with `required command not found: <command>`. The same command brings in a raised floor of an installed component, which the rebuild does not enforce; `dotsteward --instance <instance.path> install --profile <profile> --component <name> --check-only` confirms the result.
- Another machine, or a skill capture of this one, published first: `apply` moves the commits onto the new tip by itself, in a clone of its own, takes the tip's `.dotsteward/` mirrors and `flake.lock` where both sides changed them, regenerates, proves, activates and runs E2E again, then pushes; nothing to do. `publish-conflict`: both changed the same lines of the `paths`; nothing was pushed and the checkout is as it was. Show the user both sides, settle them with the `run` of the item (`git pull --rebase origin <branch>`, which needs no upstream branch, and the same `apply`) and never pick a side alone. `publish-race`: the remote moved before each of three pushes; the commits stay here and the same `apply` later finishes them. `replay-merge`: a merge commit among the unpublished commits; with the user's agreement run the `run` of the item, which lines them up on the tip.
- `writer-class`: the tree changes what only another machine writes (`paths`, `producer`). Take those changes back (the producer moves the pins), or, when the user wants this machine to be the producer, run the `run` of the item first.
- `nested-repository`: a git repository inside the checkout, which would be published as an empty gitlink: ask whether to vendor its files (remove its `.git`) or to leave it out of the instance.

## 6. Report

Report what became reproducible, the locked versions, the local activation status, the step durations (`seconds` of each step in `dotsteward apply --json`, and the gate's `validation.step_seconds` of `dotsteward txn status --json`), the tests run, the commit and remote OIDs, the exclusions made for secrets or machine state, and any unresolved upstream risk. Write the report in the language the overlay asks for, else in the user's language.
