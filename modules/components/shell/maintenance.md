# shell: update notes

Used by `dotsteward-update` when it refreshes an instance that enables the
shell component, and by framework maintainers when they refresh `seed.json`.

## Source of truth

- zsh and the two plugins follow the instance's locked nixpkgs: updating
  nixpkgs updates them, and `nix_packages.zsh.resolved` follows
  (`dotsteward pins sync` writes it; `nix_packages.zsh.expected` stays the
  sentinel `locked nixpkgs package`).
- starship is an exact pin: the newest stable GitHub release of
  `starship/starship` (`pins.latest`, adapter `github-release`, row
  `nix_packages.starship`). Pre-releases are not candidates.

## Lock entries to update together

| Lock path | Value |
| --- | --- |
| `nix_packages.starship.expected` | the release version without the `v` |
| `nix_packages.starship.official_tag` | `v<expected>` |
| `nix_packages.starship.tag_revision` | the commit of the tag: `git ls-remote https://github.com/starship/starship refs/tags/v<expected>` |
| `nix_packages.starship.source_nix_sha256` | `nix flake prefetch --json github:starship/starship/v<expected> \| jq -r .hash` |
| `nix_packages.starship.cargo_nix_sha256` | see below |
| `nix_packages.starship.resolved` | the version of `packages.<system>.starship` after the update (`dotsteward pins sync`) |

`cargo_nix_sha256` is the hash of the vendored crates, known only after a
build: set it to `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`, run
`nix build --no-link .#packages.x86_64-linux.starship.cargoDeps` in the
instance, and copy the `got:` value. The pins engine rejects the placeholder,
so it cannot be committed by mistake.

`expected` and `resolved` must be equal after a sync. When they differ, the
override did not take effect: stop and report it instead of editing the lock
by hand.

## Before accepting a new version

- Read the upstream release notes for configuration changes:
  `programs.starship.settings` of an instance is written verbatim as
  `starship.toml`, so a renamed or removed key needs an instance change
  through `dotsteward-maintain`.
- Check that `starship init zsh` still exists (the `starship-init` block of
  `~/.zshrc` calls it).
- The override keeps the nixpkgs build recipe of the locked nixpkgs. When a
  new release needs a different recipe (new build inputs, a changed Rust
  toolchain floor), the build fails: update nixpkgs first, or report the
  release as blocked.
- When the locked nixpkgs ships the pinned version or a newer one, the
  override still applies and keeps the exact pin; move the pin forward
  rather than below the nixpkgs version.

## Framework seed

`seed.json` holds the values the release's clean-install CI proved. Refresh
its `versions_lock.nix_packages.starship` with the same values an instance
lock would get, and `nix_packages.zsh.resolved` with the zsh version of the
framework's locked nixpkgs. Then update the shell fixture lock
(`tests/nix/components/shell/fixtures/instance/versions.lock.json`, the
minimal lock merged with the seed) and the `Verification` section of
`README.md`, and run `checks.x86_64-linux.component-shell`.
