# craft-anything: maintenance

Notes for `dotsteward-update` when it refreshes the craft-anything pin.

## Pin

| Lock path | Asset | Release |
| --- | --- | --- |
| `desktop_packages.craft-anything` | `craft-anything-<version>-linux-x86_64.deb` | `https://github.com/storytold/craft-anything/releases/tag/v<version>` |

The pin is `{ minimum_version, url, size, sha256 }`. It is the floor of a new machine only: installed machines follow the newest release through the local APT bridge, so raising the floor is never needed to update them.

## Latest research (`github-release` adapter)

The component declares one `github-release` row with the id `desktop_packages.craft-anything`: repository `storytold/craft-anything`, tag prefix `v`, asset `craft-anything-{version}-linux-x86_64.deb`. The size and the SHA-256 come from the release asset's metadata; they must equal the asset's line in the release's `SHA256SUMS.txt`, which the local APT bridge checks on every machine. Never take a pre-release.
