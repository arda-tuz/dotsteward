# vscode: maintenance

Notes for `dotsteward-update` when it refreshes the vscode pins.

## Pins

| Lock path | Build name | Update API |
| --- | --- | --- |
| `desktop_packages.vscode` | `linux-deb-x64` | `https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest` |
| `desktop_packages.vscode-darwin-arm64` | `darwin-arm64` | `https://update.code.visualstudio.com/api/update/darwin-arm64/stable/latest` |

Each pin is `{ minimum_version, url, size, sha256 }`. Both pins move together: they name one VS Code release.

## Latest research (`official-manifest` adapter)

The component declares one `official-manifest` row per pinned platform, with the row id equal to the lock path. Its fields:

| Field | Value | Meaning |
| --- | --- | --- |
| `at` | the lock path | the pin the row compares and updates |
| `current_field` | `minimum_version` | the pinned version |
| `manifest_url` | the update API URL above | JSON describing the newest stable build |
| `version_field` | `productVersion` | the newest version, for example `1.140.0` |
| `sha256_field` | `sha256hash` | the SHA-256 of the build's file |
| `size_url_field` | `url` | the API's direct file URL; the size is the `Content-Length` of a HEAD request to it (the API has no size field) |
| `url_template` | `https://update.code.visualstudio.com/{version}/<build>/stable` | the version-addressed download URL written into the pin |
| `source` | `https://code.visualstudio.com/updates` | release notes |

The API's `version` field is a commit hash, not the version; always read `productVersion`. The `official-manifest` adapter itself belongs to the pins engine (`engines/pins/dotsteward_pins/latest/`); these declarations are its input.

## Updating by hand

1. Read the API of each build and note `productVersion`, `url` and `sha256hash`.
2. Check that `https://update.code.visualstudio.com/<productVersion>/<build>/stable` redirects to the same file as `url`, and take its size from a HEAD request.
3. Write `minimum_version`, `url` (the version-addressed form), `size` and `sha256` into both pins and run `dotsteward pins check`.
4. Before a framework release changes `seed.json`, download both files, compare size and SHA-256, check the DEB's `Package` (`code`) and `Architecture` (`amd64`) fields, and check that the darwin archive's `Visual Studio Code.app/Contents/Info.plist` has `CFBundleShortVersionString` equal to `productVersion`; then update the verification dates in `README.md`.

Never pin the API's direct file URL: it contains a commit hash instead of the version, which the pins check refuses.

## Update channel

VS Code updates itself (Linux: the vendor's apt repository that the package's installer offers to add; macOS: the application's own updater). The pins are floors for fresh installs, not ceilings; a newer installed version is never downgraded. The test `tests/nix/components/vscode/test-vendor-repository.sh` keeps the framework from blocking the vendor's repository.
