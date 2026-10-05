# Shared test fixtures

Synthetic data shared by several test suites. Nothing here describes a real
user, machine or third-party product; hosts use `example.invalid`, packages and
repositories use the synthetic names `example-app`, `example-term` and
`example-org`. Look files up with `ds_fixture common/<path>` from a test.

| Path | Content |
| --- | --- |
| `debs/*.deb` | Fake Debian packages in the stub format (a `!<dotsteward-fake-deb>` line followed by control fields), readable by the `dpkg-deb`, `dpkg` and `apt-get` stubs. `example-app` 1.1.0, 1.2.3 and 1.3.0~rc1, `example-term` 0.9.0. |
| `apt/Packages` | An APT `Packages` index (amd64) for exactly those files: `Filename`, `Size` and `SHA256` match the files in `debs/`. |
| `github/release-latest.json` | GitHub REST "latest release" of `example-org/example-term` (`v0.9.0`); the asset `size` and `digest` values match `debs/example-term_0.9.0_amd64.deb` and `github/SHA256SUMS`. |
| `github/releases.json` | The release list: a draft (`v1.1.0`), a prerelease (`v1.0.0-rc.1`), the latest release and an older one (`v0.8.0`). |
| `github/compare.json` | GitHub REST compare result, two commits ahead of the base. |
| `github/SHA256SUMS` | Checksum file published with the latest release. |
| `vscode/update-latest.json` | A VS Code-style update API answer (`productVersion`, commit `version`, `sha256hash`, download `url`). |
| `nix/install.sha256` | The checksum file published next to a Nix installer (one hex digest). |
| `npm/example-app.json` | An npm registry document with `dist-tags` (`latest`, `next`), three versions and their `dist` records. |
| `os-release/*` | `os-release` files for Ubuntu 24.04, Ubuntu 22.04 and Debian 12 (for `DOTSTEWARD_OS_RELEASE`). |

Fixtures that git cannot carry faithfully (file modes other than 0644/0755,
unicode names, `__pycache__`, `.pyc`, private keys, home directory layouts) are
built at run time by the harness: `ds_fixture_skill_tree` and
`ds_fixture_backup_layouts` in `tests/lib/harness.sh`, secret-shaped strings
with `fake_secret`, fake packages with `ds_fake_deb`.
