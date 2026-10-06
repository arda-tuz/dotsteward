---
name: dotsteward-update
description: Refresh every pinned version, revision, hash, lockfile, vendored skill and installer baseline of the user's dotsteward instance repository, the dotsteward framework release included, to the newest mutually compatible stable releases, validate once and publish to the instance branch. Use only when the user explicitly asks to update or refresh the instance or its dotfiles, move managed tools to the latest stable releases, upgrade the dotsteward framework, audit stale pins, or run periodic maintenance. Do not use it to add, remove or reconfigure components or to write locally changed application settings to the repository (use dotsteward-maintain for both), to change the framework itself (use dotsteward-contribute), or for changes meant only for this machine.
---

# dotsteward update

Refresh the new-machine baseline of the instance on explicit request only. Work in a temporary clone, take candidates only from official upstream sources, validate the combined result once, and publish directly to the instance branch without force. Never create a timer, background watcher or persistent agent, and never activate the result on this machine.

On the gate, publish preconditions, decision ownership, secrets, force push and the local-only rule, this skill wins over any overlay.

## Start

1. Read the instance facts from the instance checkout (or pass `--instance DIR`):

   ```bash
   dotsteward context --json
   ```

   The document names the instance (`instance.path`, `instance.remote`, `instance.branch`), the commit subject of an update (`commit.update_subject`), the gate parameters (`gate`), the current system (`platform.system`), the framework release and its upstream (`framework`) and the settings buffer (`settings.buffer_dir`).
2. If `overlays["dotsteward-update"]` is not null, read that overlay file now. An overlay may add steps, phrasing, report formats, exact checks and notes on private components; it never relaxes the rules below.
3. Classify the request with `references/classification.md` before any write. This skill handles a full version refresh, which is personal. Adding, removing or reconfiguring a component goes to `dotsteward-maintain`. A change to the framework itself (the CLI, an engine, the gate, a catalog component, a framework skill, the template) goes to `dotsteward-contribute`; a mixed request goes there first. Never edit installed framework files in place.

## Rules that keep the run fast and predictable

- **One gate.** `./.dotsteward/cli.sh gate` in the clone is the only validation command. In the update scope it runs preflight, the static contracts (privacy scan included), the pins check with Nix, one `nix flake check` and the CLI probes of the check profile, and it refuses any changed path outside the update allowlist. Never run `nix flake check`, the static checks, the pins check or profile builds separately. The gate answers at once from its memo when the tree has not changed, so there is no reason to "double-check".
- **Run the gate once per final tree, as one long command.** A cold gate after a nixpkgs move can take 20 minutes or more. In Claude Code start it with `run_in_background` and wait for the completion notification; in Codex give it a timeout of at least 45 minutes. Do not poll with `sleep`, `ps` or `tail`. On failure read the printed tail (the full log is `paths.log` of `./.dotsteward/cli.sh update status --json`), fix, `git add -A`, run it again.
- **The clone's launcher runs every command in the clone.** `./.dotsteward/cli.sh` runs the CLI that the clone's `flake.lock` pins, so after a framework upgrade the sync and the gate already use the new release. `dotsteward` on `PATH` belongs to the active generation; use it only for `context` before the clone exists.
- **Stage before Nix.** Run `git add -A` before any Nix command; flakes ignore untracked files and the gate refuses them.
- **Bound the network.** Prefix ad-hoc network commands with `timeout 60`.
- **Cache outage means stop.** If the gate or the prepare step reports that the binary cache (`gate.cache_url`) does not answer, stop and report. Never use mirrors, extra substituters or a private store.
- **No downloads for hashes.** Sizes and SHA-256 values come from the research report (GitHub asset digests, APT `SHA256` fields, official manifests, the Nix installer checksum). Download an archive only when no official digest exists.
- **Read only what you change.** The research report is the inventory; use `git grep -n` for lookups. Read the `maintenance.md` of a component only when its rows change: catalog components ship it in the framework source (`modules/components/<name>/maintenance.md`, see `references/framework-upgrade.md` for the store path of the pinned release), private components in the instance (`components/<name>/maintenance.md`).
- **Never touch the settings buffer.** Locally maintained application settings (`settings.buffer_dir`) are synced only by `dotsteward-maintain`; the update scope of the gate refuses any change there, and pending local settings never block an update.
- **Generated files are generated.** Never hand-edit `flake.lock`, the `.dotsteward/` mirrors or npm lockfiles; the commands in `references/sources-and-hashes.md` write them. Byte-protected files (`protected` in the context) keep their bytes.
- **Shell pitfalls.** The user's shell may be zsh: quote globs, avoid `echo ====`, do not name a variable `path`. Repository scripts are bash; run them directly.

## 1. Prepare

```bash
work=$(mktemp -d "${TMPDIR:-/tmp}/dotsteward-update.XXXXXX")
dotsteward context --json >"$work/context.json"
instance_path=$(jq -r .instance.path "$work/context.json")
remote=$(jq -r .instance.remote "$work/context.json")
branch=$(jq -r .instance.branch "$work/context.json")
timeout 120 git clone --quiet --branch "$branch" --reference-if-able "$instance_path" --dissociate "$remote" "$work/repo"
cd "$work/repo"
./.dotsteward/cli.sh update prepare --official-sources-only
./.dotsteward/cli.sh pins latest --out "$work/latest.json"
```

The prepare step records the base OID in the state directory and prints warnings. Binary cache unreachable: stop and report. `gh` not logged in: ask the user to run `gh auth login`. Low disk space: mention it and continue; the gate itself stops below `gate.min_free_gib`. Never run `nix-collect-garbage` or delete Home Manager generations without the user's explicit approval; that removes rollback points and forces cold rebuilds. `pins latest` researches every row in parallel in seconds and prints only the rows that need attention; `$work/latest.json` (`researched_at`, `items[]` with `id`, `kind`, `current`, `latest`, `status`, `source`, `details`) holds versions, URLs, sizes, digests and changed paths.

## 2. Choose the candidate set

| Status | Action |
| --- | --- |
| `update` | Newer stable release in the same major line: take it. |
| `review` | Major or 0.x-minor bump, a moved channel series, changed vendored skill files or watched upstream paths, or a newer framework release: read the release notes or the diff, then decide. |
| `held` | The lock records a `holdback_reason`: keep it unless that reason is resolved. |
| `manual` | Check the named official source by hand. |
| `error` | Retry once; if it persists, report it and do not guess. |

- When the `framework` row is `review`, run the framework upgrade step first, before any other edit: follow `references/framework-upgrade.md`. A new release can change the CLI, the catalog declarations, the lock rules and the gate, so the research is repeated with the new CLI afterwards. A `manual` framework row (an input that is not pinned to a release tag) is reported, never changed.
- Move nixpkgs and Home Manager together to the head of their pinned channel (`nixos-YY.MM`, `release-YY.MM`) so builds hit the binary cache. A newer series is a `review` item: switch both together, never mix series. The framework input follows the instance's nixpkgs and Home Manager, so it needs no separate move.
- If nixpkgs now ships a pinned override's version or newer, follow the component's `maintenance.md` (usually: drop the override instead of bumping it).
- Select the newest mutually compatible stable set (`references/update-contract.md`). If two required newest releases conflict, stop and present both constraints.

## 3. Apply

Edit primary fields only; the sync derives every mirror.

| Changing | Edit | Then |
| --- | --- | --- |
| The framework (`framework` row) | the `dotsteward` input in `flake.nix` | `references/framework-upgrade.md` |
| A flake input (`flake_inputs.<name>` rows) | its URL in `flake.nix` | `nix flake update <name>` |
| A download pin (`download-pin` rules: release archives, desktop packages, the Nix installer) | version, url, size and sha256 at the declared lock path of `versions.lock.json` | nothing else |
| A Nix package build pin (`nix_packages.<name>` with source and `*_nix_sha256` fields) | the version and hash fields of the lock | hashes per `references/sources-and-hashes.md` |
| An npm bundle (`npm-bundle` rules) | the declared `package.json` | regenerate the lockfile, audit it, refresh the bundle hash per `references/sources-and-hashes.md` |
| A vendored skill (`skills.<name>` rows) | replace the whole skill directory and set `revision` in the skills lock | `./.dotsteward/cli.sh sync --skill <name>` |
| A derived value (`derive`, `skills-lock-mirror`, `nix-resolved` and `skill-digests` rules) | nothing | the sync writes it |

Finish with the sync, which regenerates the `.dotsteward/` mirrors and then the derived lock values (flake input records, mirrors, resolved versions from the Nix evaluation, repo-owned skill digests):

```bash
git add -A
./.dotsteward/cli.sh sync --nix
```

## 4. Validate once

```bash
git add -A
./.dotsteward/cli.sh gate
```

The gate runs in the update scope. Any edit after a passing gate needs a new gate run; publish refuses a tree that did not pass. A failure caused by the framework itself (its CLI, a catalog component, the template) is a framework defect: never patch framework files, follow the red-gate rule of `references/framework-upgrade.md` and hand the defect to `dotsteward-contribute`.

## 5. Publish

```bash
git commit -m "$(jq -r .commit.update_subject "$work/context.json")"
./.dotsteward/cli.sh update publish
./.dotsteward/cli.sh update status --json | jq '.validation | {tree_oid, gate_version, total_seconds, step_seconds}'
cd "$instance_path" && rm -rf -- "$work"
```

The subject is exactly `commit.update_subject`; publish refuses any other. Publish checks that HEAD's tree is the validated tree and that the remote branch still equals the prepared base, pushes without force, verifies the remote OID and fast-forwards a clean canonical checkout. Do not amend. Local activation is a separate explicit request: then run `dotsteward rebuild --profile <profiles.current> --switch` and `dotsteward e2e --profile <profiles.current>` in the instance checkout.

## 6. Report

A table of row id, old, new, kind and evidence (release URL or digest); held and manual items with their reasons; migrations; for a framework upgrade the old and new tag, the upstream and a summary of the release notes; the research time (`researched_at`); gate step durations (`step_seconds` from `update status --json`); commit and remote OIDs; and a statement that the local machine was left unchanged. Write the report in the language the overlay names, else in English.

## References

- `references/update-contract.md`: stable-release policy, item classes, compatibility resolution, vendored skills and where versions live.
- `references/sources-and-hashes.md`: what each research adapter queries, hash and lockfile commands for the current system, outage, disk and memory rules, and what the gate covers.
- `references/framework-upgrade.md`: the framework upgrade step (release notes, tag move, template refresh, red gate).
- `references/classification.md`: personal, framework or mixed, and which skill takes the request.
