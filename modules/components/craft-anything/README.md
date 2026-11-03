# craft-anything

Craft Anything, an application that explains how software works and helps build your own, from the official DEB that each GitHub release of [storytold/craft-anything](https://github.com/storytold/craft-anything) carries, kept up to date through the local APT bridge with plain `apt update && apt upgrade`.

Enable it in `workstation.toml`:

```toml
[components.craft-anything]
enable = true
```

Preselected for new instances on: `x86_64-linux`.

## What it installs

| Platform | Default method | Also supported | Pin (`versions.lock.json`) |
| --- | --- | --- | --- |
| Linux (x86_64) | `deb` | none | `desktop_packages.craft-anything` |

- `deb` (Linux): the DEB package `craft-anything` (architecture `amd64`), the release asset `craft-anything-<version>-linux-x86_64.deb`. In a `fresh` profile, `dotsteward install` downloads the pinned asset, verifies its size and SHA-256 and adds it to the single apt transaction when the installed `craft-anything` is older than `minimum_version`; a newer installed version is kept, never downgraded. In an `adopt` profile it is not installed by the rebuild: run `dotsteward install --profile <profile> --component craft-anything` once (it needs `sudo`).
- Updates: the vendor runs no APT repository, so the same transaction sets up the local APT bridge (`/etc/apt/sources.list.d/dotsteward-apt-bridge.sources`, served from `/var/lib/dotsteward/apt-bridge`). Before every `apt update` it reads the newest release of `storytold/craft-anything`, verifies the asset against the release's `SHA256SUMS.txt` and offers it as the only version of `craft-anything`, so a plain `apt upgrade` installs it. Nothing upgrades the package unattended.
- darwin: not supported; an instance whose `nix.systems` holds a darwin system cannot enable it.

The pin holds `minimum_version`, `url`, `size` and `sha256`; the URL is the asset of release `v<minimum_version>`, and the pins check (`dotsteward pins check`) requires exactly that form. `dotsteward pins latest` compares the pin with the newest release (`github-release` adapter, see `maintenance.md`). `dotsteward init` starts a new instance from `seed.json`.

## Checks

| Check | What it verifies |
| --- | --- |
| commands | `craft-anything` and `craft-anything-cli` are on `PATH` |
| E2E `package` (every profile, parallel) | the installed `craft-anything` is at least `minimum_version`, the package ships its desktop entry, `craft-anything-cli --version` answers, and `apt-cache policy craft-anything` shows the local APT bridge |

## Verification (catalog facts)

The release layout (asset name, `SHA256SUMS.txt`, package name `craft-anything`, architecture `amd64`, the commands `/usr/bin/craft-anything` and `/usr/bin/craft-anything-cli`, a desktop entry under `/usr/share/applications/`, maintainer scripts that only refresh the desktop, MIME and icon caches and add no APT source) was verified on 2026-11-02 from release `v0.2.0` of storytold/craft-anything.
