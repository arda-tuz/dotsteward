# herdr: update notes

Used by `dotsteward-update` when it refreshes an instance that enables herdr,
and by framework maintainers when they refresh `seed.json`.

## Source of truth

- Latest version: the newest stable GitHub release of `herdrdev/herdr`
  (`pins.latest`, adapter `github-release`). Pre-releases are not candidates.
- The instance flake input `herdr` points at the release tag
  (`github:herdrdev/herdr/v<version>`). Move it by changing the tag in
  `flake.nix` and running `nix flake update herdr`; never pin a branch.

## Lock entries to update together

| Lock path | Value |
| --- | --- |
| `flake_inputs.herdr.reference` | the input URL, `github:herdrdev/herdr/v<version>` |
| `flake_inputs.herdr.revision` | `locked.rev` of the `herdr` node in `flake.lock` |
| `flake_inputs.herdr.nar_hash` | `locked.narHash` of the same node |
| `flake_inputs.herdr.version` | `<version>` without the `v` |
| `nix_packages.herdr.expected` | derived from `flake_inputs.herdr.version` (the pins engine writes it) |
| `nix_packages.herdr.resolved` | the version of `inputs.herdr.packages.<system>.herdr` after the update |

The pins engine checks that the reference, revision and NAR hash agree with
`flake.lock`, that `nix_packages.herdr.expected` equals the derived version,
and that `nix_packages.herdr.resolved` equals the version Nix evaluates for
the package (`dotsteward pins sync` writes both). When `expected` and
`resolved` differ after a sync, the release tag and the package version
disagree upstream: stop and report it instead of editing the lock by hand.

## Before accepting a new version

- Read the upstream release notes for configuration changes. The settings
  target manages `~/.config/herdr/config.toml`; a release that renames a key
  an instance tracks in its buffer needs a buffer change through
  `dotsteward-maintain`, not through the update.
- Check that `herdr server reload-config` still exists (the reload hook
  `herdr-server` calls it) and that the configuration directory is still
  `$XDG_CONFIG_HOME/herdr`, else `~/.config/herdr`, on Linux and macOS
  (`src/config/io.rs` upstream). If either changes, update the component and
  the verification status in `README.md`.
- The upstream flake must keep `packages.<system>.herdr` for every system in
  `nix.systems`; the generation fails with a clear message otherwise.

## Framework seed

`seed.json` holds the values the release's clean-install CI proved. Refresh
its `flake_inputs.herdr.url` and `versions_lock` together, with the same
values an instance lock would get; `dotsteward static --only seeds` and the
component tests check that they agree.
