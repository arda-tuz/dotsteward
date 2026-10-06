# Update contract

## Contents

1. Stable-release policy
2. Item classes
3. Compatibility resolution
4. Vendored skills
5. Where versions live

## Stable-release policy

Accept only releases the upstream owner marks as stable. A Git tag alone is not enough when the release notes call it experimental or a prerelease. Prefer immutable release assets, registry integrity records, signed APT indexes and source commits behind tags. `pins latest` records the research time (`researched_at`) in its report; quote it in the final report because latest-version facts expire.

Keep exact pins exact. For applications that use a minimum baseline plus the vendor's native updater, raise the installation baseline but never downgrade a newer local installation. A major-version change needs release-note review and explicit migration evidence. The framework release follows the same rule: every release between the pinned and the newest tag is read before the tag moves (`framework-upgrade.md`).

## Item classes

| Class | Examples | Update rule |
| --- | --- | --- |
| Exact pin | flake inputs (the framework input included), npm dependencies, Nix package sources, release archives | move to the chosen stable release with new hashes |
| Minimum baseline with native updates | desktop applications that update themselves, such as VS Code or Claude Code | raise the baseline; the application keeps updating itself |
| Compatibility floor | tool versions another tool requires exactly, Node.js engine floors | follow the consuming tool's stated requirement |
| Source snapshot | vendored skills, watched upstream paths (`git-compare` rows) | re-inspect when upstream paths changed |
| Platform package | local APT floors | informational; change only with evidence |

A `holdback_reason` in the lock keeps an item on its current version until the reason is resolved (for example an acceptance test that needs physical hardware). Record every new holdback with the same field and the observed newer version (`latest_stable_version`).

## Compatibility resolution

Build the constraints before choosing the final set:

- nixpkgs and Home Manager on the same release series; the framework input follows both, so a framework release that needs a newer series says so in its notes;
- Node.js engine ranges and npm peer dependencies;
- plugin-to-host version floors;
- application configuration schema changes;
- exact tool versions that another tool's workflow requires;
- feature probes required by downstream tools (the components' probes; the gate runs them on the check profile).

If the newest A needs an unstable B, keep A at its newest compatible stable release. If two required newest stable releases conflict, do not choose silently: present both constraints and ask. "All latest" is true only when the combined graph passes the gate.

## Vendored skills

Compare the upstream directory at the new revision with the vendored copy, including license and metadata. Replace the complete skill directory below the vendored skills directory (`[skills] vendor_dir`, default `agent/skills`), keep any recorded `source_transform`, update `revision` in the skills lock (`[skills] lock`, default `agent/skills.lock.json`), then run `./.dotsteward/cli.sh sync --skill <name>`. Skills marked `release_bound` compare against the upstream's latest release tag instead of its default branch. On existing machines a rebuild backs up and replaces any locked skill whose installed copy differs from the lock, and the end-to-end checks fail until it does; skills that are not in the lock are never touched.

The framework skills (`dotsteward-*`) are never entries of the skills lock: they ship with the framework release and move only with the framework upgrade step.

## Where versions live

`versions.lock.json` is the single source of truth. `flake.nix`, the installers and the validators read it; `flake.lock`, npm `package.json` and `package-lock.json` files, the skills lock and the `.dotsteward/` mirrors are mirrors checked by `pins check` and refreshed by `./.dotsteward/cli.sh sync`. Prose documentation states policy, not version numbers, so a version update never needs README or AGENTS.md edits unless a policy changes.
