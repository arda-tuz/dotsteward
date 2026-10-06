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
- **One gate, run once per final tree:** `dotsteward gate --scope maintain`. It runs the preflight, the static checks (privacy scan included), the pins check, one `nix flake check` and the CLI probes of the candidate generation, and answers from its memo for an unchanged tree. Never run `dotsteward static`, `dotsteward pins check`, `nix flake check` or profile builds separately. Start the gate in the background (Claude Code `run_in_background`; Codex with a timeout of at least 45 minutes) and wait for it once instead of polling.
- **Stage before Nix** (`git add -A`): flakes ignore untracked files, and the gate refuses them.
- **Bound the network** with `timeout 60` on every command you run by hand that reaches the network. If the binary cache (`gate.cache_url`) is unreachable, stop and report; never use mirrors or extra substituters.
- **Read narrowly.** Read `references/framework-map.md`, then only what it lists for the affected components: their `maintenance.md` and `README.md` in the framework source, the instance files they touch, and the overlay. Use `git grep -n` for everything else.
- **Protected and generated files.** The paths under `protected` in the context are byte-protected. Never hand-edit `flake.lock` (change inputs with `nix flake lock` or `nix flake update <input>`), the `.dotsteward/` mirrors, `bootstrap.sh` or `.dotsteward/cli.sh` (framework-owned bytes). Versions live in `versions.lock.json`; after changing pins run `dotsteward sync`.
- **No secrets or machine state in Git:** credentials, tokens, sessions, caches, histories, databases, sockets, logs, machine identifiers and project indexes stay out.
- **Settings files only through the buffer.** Application settings files that the application writes itself are never linked or replaced. Only the entries of the settings buffer (`settings.buffer_dir` of the context) are synchronized, by `dotsteward settings` (`references/local-maintained-files.md`). This skill is the only one that writes the buffer; decisions on conflicts and deletions are always the user's.
- **Framework files are read-only.** Never edit installed framework files (the skill links, the store paths, the framework input); framework changes go through `dotsteward-contribute`.

## 1. Start

1. From the instance checkout, read the instance facts once; later steps use them (paths, profiles, commit rules, overlays, components, settings ids). If the location of the checkout is unknown, ask the user, or set `DOTSTEWARD_INSTANCE` to it.

   ```bash
   dotsteward context --json
   ```

2. If `overlays["dotsteward-maintain"]` in that document is not null, read that overlay file now. An overlay may add steps, phrasing, report formats and notes on private components; it never relaxes the rules of this skill.
3. Classify the request with `references/classification.md` before any write. Personal requests continue here. Framework requests go to `dotsteward-contribute`. Mixed requests go to `dotsteward-contribute` first, which ends with an upgrade of the instance to the new framework release; the personal part then continues here on the upgraded instance.
4. Check the checkout and open the transaction:

   ```bash
   cd "$(dotsteward context --json | jq -r .instance.path)"
   test "$(git remote get-url origin)" = "$(dotsteward context --json | jq -r .instance.remote)"
   git status --porcelain
   dotsteward preflight --read-only --json --profile "$(dotsteward context --json | jq -r .profiles.current)"
   dotsteward update prepare --official-sources-only --scope maintain
   dotsteward settings status
   ```

- A failed remote check means this is not the instance checkout: stop and ask.
- Non-empty `git status`: ask whether those changes belong to this transaction.
- The preflight `route` must be `fast` (exit 0). Exit 3 is the adaptive route: report the reasons from the preflight document, write no tracked file, and ask how to proceed.
- The prepare step records the base OID and requires `HEAD` to equal `origin/<branch>`. If `HEAD` is behind, run `git pull --ff-only` and prepare again; if it is ahead, ask.
- Prepare warnings: an unreachable binary cache means stop and report; `gh` not logged in means ask the user to run `gh auth login`; low disk space is only reported (the gate stops below `gate.min_free_gib` GiB). Never collect garbage or delete Home Manager generations without the user's explicit approval.
- Settings entries in `local-changed` or `local-deleted` are local settings not yet in the repository: ask whether to write them in this transaction (next section).

## Locally maintained settings

When the user wants local settings written to the repository, or accepts pending entries found at the start, follow the "Write local settings to the repository" workflow in `references/local-maintained-files.md`: `status --json`, a decision report for every entry that needs a decision, `resolve` per the user's answer, `flush`, then the usual gate, commit, rebuild, E2E and publish, and finally `reconcile`. The decision report is plain text by default; an overlay may ask for another format. Tracking or untracking a setting is a normal transaction with `track`, `track-file` or `untrack`.

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
2. the pins in `versions.lock.json` at the lock paths the component's rules read (and `flake.nix` plus `nix flake lock` for a new flake input), then `dotsteward sync`, which regenerates the `.dotsteward/` mirrors and the derived lock values;
3. an idempotent installer: the framework methods (`nix`, `official-binary`, `deb`, `app-archive`, `external`) already are; a component hook script must be safe to rerun and honour `DOTSTEWARD_CHECK_ONLY=1`, and `dotsteward install --profile <profile> --check-only` must pass;
4. a static assertion (an instance script in `[gate] static`, or a component check) and a real smoke or E2E check (`checks.commands`, `checks.e2e`, `probes`);
5. backup, adoption and rollback coverage when a user file is replaced (`bootstrap.backupPaths`, `rebuild.adoptPaths`, `rollback.managedLinks`, `rollback.forceLinkedRestore`);
6. the instance `README.md`, `AGENTS.md` and focused docs (policy, not version numbers);
7. the update allowlist, through the component's `gate.updatePaths` or `[gate] update_allowlist`, when version updates may need to touch the new paths; it never matches the settings buffer;
8. the removal of every stale reference when replacing a component.

New tracked files follow the new-file checklist in `references/framework-map.md`. For a new instance skill, vendor the complete directory under `agent/skills/<name>/` (`[skills] vendor_dir`): `SKILL.md`, `agents/openai.yaml`, a license, and only `references/`, `scripts/` and `assets/` besides. Add its entry to `agent/skills.lock.json` (`[skills] lock`), then refresh its digests:

```bash
dotsteward pins sync --skill NAME
```

`dotsteward agents install` (run by the rebuild) installs it into the canonical skill root and creates the per-agent links. Framework skills (`dotsteward-*`) never go into the skills lock.

## 4. Validate once

```bash
git add -A
dotsteward gate --scope maintain
```

Also exercise the changed component through one real user-facing path when the gate does not (for example an isolated CLI workflow), not only `--version`.

## 5. Commit, activate, verify, publish

The order is fixed, because the rebuild and the E2E checks need a clean committed tree:

```bash
profile=$(dotsteward context --json | jq -r .profiles.current)
git commit -m "<type>: <summary>"
dotsteward rebuild --profile "$profile" --switch
dotsteward e2e --profile "$profile" --expected-remote-base "$(dotsteward update status --json | jq -r .candidate.base_oid)"
dotsteward update publish --scope maintain
```

- Use a conventional commit subject (`feat`, `fix`, `perf`, `refactor`, `docs`, `chore`, `test`, `build`, `ci`, `style`, `revert`; the list is `commit.conventional_types` of the context); the publish step rejects any other subject.
- Run the rebuild only when local activation is requested or clearly expected, and publish only when the user wants the remote updated.
- If E2E fails, fix it, add a new commit (no amend), run the gate again, then E2E again. A failed check means no push.
- If the rebuild warns that the login shell is still on a versioned Nix path, ask the user to run the same rebuild once in a terminal; moving the login shell needs `sudo`.
- The publish step checks the validated tree, the remote base and the commit subjects, pushes without force and verifies the remote OID.

## 6. Report

Report what became reproducible, the locked versions, the local activation status, the gate step durations (`validation.step_seconds` of `dotsteward update status --json`), the tests run, the commit and remote OIDs, the exclusions made for secrets or machine state, and any unresolved upstream risk. Write the report in the language the overlay asks for, else in the user's language.
