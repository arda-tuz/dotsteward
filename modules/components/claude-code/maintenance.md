# claude-code: update notes

Used by `dotsteward-update` when it refreshes an instance that enables
claude-code, and by framework maintainers when they refresh `seed.json`.
Only the pins of the methods the instance uses on the platforms of
`nix.systems` are declared; refresh those.

## official-binary

Source of truth: the stable release channel of the vendor's release bucket
`https://downloads.claude.ai/claude-code-releases/stable` (`pins.latest`,
adapter `official-manifest`, one row per release platform).

1. `<base>/stable` is a text file holding the current stable version. The
   default `latest` channel of the application runs ahead of it (on
   2026-10-06: stable 2.1.285, latest 2.1.291); pins follow the stable
   channel only.
2. `<base>/<version>/manifest.json` lists every release platform under
   `platforms.<release platform>` with `checksum` (hex SHA-256) and `size`.
3. The build is `<base>/<version>/<release platform>/claude`, the executable
   itself.

Lock entries to update together, for each release platform of the instance
(`linux-x64` for `x86_64-linux`, `darwin-arm64` for `aarch64-darwin`):

| Lock path | Value |
| --- | --- |
| `agent_tools.claude-code.<release platform>.version` | the stable version |
| `agent_tools.claude-code.<release platform>.url` | `<base>/<version>/<release platform>/claude` |
| `agent_tools.claude-code.<release platform>.size` | `platforms.<release platform>.size` of the manifest |
| `agent_tools.claude-code.<release platform>.sha256` | `platforms.<release platform>.checksum` of the manifest |

All release platforms move to the same version in one change. The
`download-pin` rules check that each URL is HTTPS and contains
`/<version>/<release platform>/claude`, the size is a positive integer and
the digest 64 hex digits.

## deb

Source of truth: the stable APT repository
`https://downloads.claude.ai/claude-code/apt/stable` (`pins.latest`, adapter
`apt-index`): the newest `Version` of package `claude-code` in
`dists/stable/main/binary-amd64/Packages`, with its `Filename`, `Size` and
`SHA256`.

| Lock path | Value |
| --- | --- |
| `desktop_packages.claude-code.minimum_version` | the Debian version (`<version>-<revision>`) |
| `desktop_packages.claude-code.url` | `<repository>/<Filename>` |
| `desktop_packages.claude-code.size` | `Size` |
| `desktop_packages.claude-code.sha256` | `SHA256` |

The APT index can lag behind the release bucket. An instance that keeps an
older floor on purpose records why in `desktop_packages.claude-code.holdback_reason`
(the row is then reported as held) and may note the newest release it saw;
remove the reason when the index catches up.

## Before accepting a new version

- Read the release notes for changes to `settings.json`, `~/.claude.json`,
  the skills directory (`~/.claude/skills`) or the agent rules file
  (`~/.claude/CLAUDE.md`). A renamed setting an instance tracks in its buffer
  needs a buffer change through `dotsteward-maintain`, not through the
  update.
- Check that `claude --version` still prints `<version> (Claude Code)`; the
  `official-binary` version regex depends on it.
- Check the setup documentation (`https://code.claude.com/docs/en/setup`)
  for changes to the update behaviour: the launcher layout under
  `~/.local/share/claude/versions/`, the handling of a custom launcher, and
  the `DISABLE_AUTOUPDATER` and `DISABLE_UPDATES` switches. Update the
  Self-update and Verification status sections of `README.md` when it
  changes.
- A major version needs review (`major_version_review_required`).

## Framework seed

`seed.json` holds the values the release's clean-install CI proved: both
release platforms of `agent_tools.claude-code` and
`desktop_packages.claude-code`, without instance-only fields such as
`holdback_reason`. Refresh them together with the same values an instance
lock would get; `dotsteward static --only seeds` and the component tests
check that they agree with the declared pins.
