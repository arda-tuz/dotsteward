# Update policy

How an instance moves to newer versions: which releases qualify, what an
update may change, and how the change is proven before it is published.
The `dotsteward-update` skill follows this policy step by step;
[pins-engine.md](pins-engine.md) describes the research and consistency
tools it uses.

## Principles

- **Official stable releases only.** A release qualifies when its upstream
  owner marks it stable. A tag alone is not enough when the notes call it
  experimental or a prerelease. Prefer immutable release assets, registry
  integrity records, signed APT indexes and source commits behind tags.
- **Repository updates are deliberate.** Nothing updates the instance in
  the background or on a schedule; every refresh is a transaction you
  start, validated by the gate before it is pushed.
- **Applications may update themselves.** For applications that ship their
  own updater, the pin is a minimum baseline: an update raises the
  baseline, and a newer local installation is never downgraded.
- **Major versions need review.** A new major version, a new release
  series of nixpkgs and Home Manager, or a new framework release is
  reported as `review`; it moves only after its release notes have been
  read and the migration is understood.
- **All latest means the combined graph passes.** When the newest A needs
  an unstable B, A stays at its newest compatible stable release; two
  conflicting requirements are presented, never decided silently.

## The `policy` section

`versions.lock.json` records the policy, and the static checks hold the two
fixed values:

| Key | Template value | Meaning |
| --- | --- | --- |
| `official_sources_only` | `true` | Versions come only from official sources. |
| `persistent_agentic_updates` | `false` (required) | No agent updates the instance in the background. |
| `scheduled_repository_updates` | `false` | No scheduled refreshes of the repository. |
| `native_application_updates` | `true` (required) | Applications with their own updater keep it. |
| `major_version_review_required` | `true` | A major version change waits for review. |

## Item classes

| Class | Examples | Update rule |
| --- | --- | --- |
| Exact pin | flake inputs (the framework included), npm dependencies, Nix package sources, release archives | move to the chosen stable release with new hashes |
| Minimum baseline | applications that update themselves | raise the baseline; the application keeps updating itself |
| Compatibility floor | versions another tool requires exactly, Node.js engine floors | follow the consuming tool's stated requirement |
| Source snapshot | vendored skills, watched upstream paths | re-inspect when the watched paths changed |
| Platform package | local APT floors | informational; change only with evidence |

A `holdback_reason` on a lock entry keeps it on its version until the
reason is resolved (for example an acceptance test that needs hardware);
`pins latest` reports it as `held`.

## Scopes

Every change to an instance is a transaction with a scope:

| Scope | What may change | Commit subjects |
| --- | --- | --- |
| `update` | only paths in the update allowlist; the clone must start clean | the last commit's subject is exactly `commit.update_subject` |
| `maintain` | anything | every commit is a conventional commit |

The update allowlist is the union of:

- the framework defaults: `flake.nix`, `flake.lock`, the versions lock, the
  skills lock, the vendored skill directories, the `.dotsteward/` mirrors
  and launcher, and the `bootstrap.sh`, `rebuild.sh`, `rollback.sh` and
  `update.sh` wrappers;
- `gate.updatePaths` of every enabled component
  ([component-contract.md](component-contract.md#updates));
- `gate.update_allowlist` of `workstation.toml`.

Entries are extended regular expressions matched against whole paths. The
settings buffer is never part of it: an update-scope transaction that
touches `settings.buffer_dir` is refused, whatever the entries say. Only
the maintain skill writes the buffer ([settings-buffer.md](settings-buffer.md)).

## A refresh, step by step

1. `dotsteward update prepare --official-sources-only --scope update`
   records the base in a clean clone; it warns when the binary cache does
   not answer or the Nix store is short of space.
2. `dotsteward pins latest --out report.json` researches every pin; rows
   with `update` or `review` are the candidates.
3. The chosen versions go into `versions.lock.json` and `flake.nix`, with
   hashes computed from the official artifacts; `dotsteward sync --nix`
   refreshes the derived values and mirrors.
4. `dotsteward gate --scope update` proves the tree once: static checks,
   privacy scan, `pins check`, `nix flake check` and the CLI probes.
5. One commit with the update subject, then
   `dotsteward update publish --scope update` pushes it without force,
   only when the remote branch is still at the base and the committed
   tree is the proven tree.

A red gate publishes nothing. The binary cache being unreachable stops the
refresh; no mirrors or extra substituters are added. The gate never frees
disk space on its own: deleting generations removes rollback points.

## Framework upgrades

The framework is an exact pin like any other, with the `framework` row of
`pins latest`. When it reports `review`, every release between the pinned
and the newest tag is read first. Then the tag in `flake.nix` moves,
`nix flake update dotsteward` locks it, `bootstrap.sh` and
`.dotsteward/cli.sh` are refreshed from the new release's `template/`,
`dotsteward sync` runs, and the same single gate decides. A red gate leaves
the instance on the old release. Framework skills move only with this step:
they are never entries of the skills lock.
