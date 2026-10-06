# claude-code

Claude Code, the coding agent CLI (`claude`), on Linux and darwin, with its
agent rules file, skill link root and settings targets.

Enable it in `workstation.toml`:

```toml
[components.claude-code]
enable = true
```

## Install

| Method | Platforms | What it does |
| --- | --- | --- |
| `official-binary` (default) | Linux, darwin | Downloads the vendor's native build of the pinned release, checks its size and SHA-256 against `versions.lock.json` and installs it as a regular file at `~/.local/bin/claude`, user level, in every profile mode. |
| `deb` | Linux | Installs the vendor's DEB from the official APT repository in the system package transaction, when the installed version is older than the pinned floor. System level: fresh-mode profiles only; adopt-mode profiles report it as not managed. |
| `external` | Linux, darwin | Installs nothing; checks that `claude` is on `PATH`. For machines where Claude Code is installed by other means. |

Choose a method per platform with `method` or `method_by_platform`:

```toml
[components.claude-code]
enable = true
method_by_platform = { linux = "deb", darwin = "official-binary" }
```

### official-binary

| Platform | Release platform | Lock path | Download |
| --- | --- | --- | --- |
| Linux (`x86_64-linux`) | `linux-x64` | `agent_tools.claude-code.linux-x64` | `https://downloads.claude.ai/claude-code-releases/<version>/linux-x64/claude` |
| darwin (`aarch64-darwin`) | `darwin-arm64` | `agent_tools.claude-code.darwin-arm64` | `https://downloads.claude.ai/claude-code-releases/<version>/darwin-arm64/claude` |

Each lock entry holds `version`, `url`, `size` and `sha256`. The download is
the executable itself (no archive). The installed version is read from
`claude --version`, which prints `<version> (Claude Code)`.

The policy is `policy = "at-least"`: a `claude` at or above the pinned
version satisfies the method and is never replaced or downgraded. That
includes the launcher of the vendor's own native installer, a symlink
`~/.local/bin/claude -> ~/.local/share/claude/versions/<version>`. A symlink
or other non-regular file older than the pin is refused, never replaced:
remove it (or run `claude update`) and rebuild. An older regular file is
backed up and replaced by the pinned build.

### deb

The pin `desktop_packages.claude-code` holds `minimum_version` (a Debian
version such as `2.1.285-1`), `url`, `size` and `sha256` of the DEB in
`https://downloads.claude.ai/claude-code/apt/stable`. The downloaded DEB
must declare the package `claude-code` and the architecture `amd64`; the
floor is checked again after the install. APT installations do not update
themselves; the next pin refresh raises the floor.

### external

The check passes when `claude` is on `PATH`; no version is asserted and no
pin is read.

## Self-update

The native build updates itself in the background by default. What happens
depends on what `~/.local/bin/claude` is:

- The vendor's launcher symlink: updates switch the launcher to the new
  version. Newer than the pin, it keeps satisfying `official-binary`.
- The regular file `official-binary` installs: the vendor treats it as a
  custom launcher and leaves it in place. Updates still download every new
  version into `~/.local/share/claude/versions/` and keep all of them on
  disk (automatic cleanup is disabled for a custom launcher), but the
  version that runs stays the pinned one until the pin is refreshed. Such
  an update reports success while nothing changes on `PATH`.

dotsteward does not change the vendor's update setting: Claude Code reads it
from the user's own `~/.claude/settings.json`, and the framework's lock
policy `native_application_updates = true` lets native applications update
themselves. An instance that installs with `official-binary` should switch
background updates off, so the unused downloads stop, by tracking this entry
in `local-maintained-files/buffer.toml`:

```toml
[[entries]]
id = "claude-code-no-background-updates"
target = "claude-settings"
key = ["env", "DISABLE_AUTOUPDATER"]
value = "1"
```

`DISABLE_AUTOUPDATER` stops the background check only; `claude update` still
works. `DISABLE_UPDATES` (same place, value `"1"`) blocks every update path,
including `claude update` and `claude install`. To let the vendor manage the
installation instead, remove `~/.local/bin/claude` and run `claude update`:
the launcher symlink that results satisfies `official-binary` as long as it
is not older than the pin.

## Settings

Claude Code writes both files itself, so Home Manager never links them. The
component declares two settings targets for the local-maintained-files
engine:

| Target | Path (Linux and darwin) | Format | Missing file | Backup |
| --- | --- | --- | --- | --- |
| `claude-settings` | `~/.claude/settings.json` | JSON | created, mode 0644 | yes |
| `claude-global` | `~/.claude.json` | JSON | left missing | no |

`~/.claude.json` is the application's own state (sign-in, the recorded
install method, caches); the engine edits only the entries an instance
tracks with `target = "claude-global"`, never creates the file and never
backs it up. Neither target has a reload hook: Claude Code reads both at
start.

## Agent rules and skills

- The instance agent rules file is linked to `~/.claude/CLAUDE.md` (no
  forced overwrite of an existing file) in every profile.
- `~/.claude/skills` is a skill link root: each skill is a relative link
  `../../.agents/skills/<name>`.
- Bootstrap backup paths: `~/.claude/CLAUDE.md`, `~/.claude/settings.json`,
  `~/.claude/skills`.
- Rollback removes the managed link `~/.claude/CLAUDE.md`.

## Pins

| Method | Rule | Latest |
| --- | --- | --- |
| `official-binary` | `download-pin` at `agent_tools.claude-code.<release platform>` for the release platform of every system in `nix.systems`; the URL contains `/<version>/<release platform>/claude` | `official-manifest`: the version of the stable channel (`https://downloads.claude.ai/claude-code-releases/stable`), then `checksum` and `size` of the release platform in that version's `manifest.json` |
| `deb` | `download-pin` at `desktop_packages.claude-code`; the URL contains `/claude-code_<minimum_version>_amd64.deb` | `apt-index` of `https://downloads.claude.ai/claude-code/apt/stable`, package `claude-code`; a `holdback_reason` keeps the pin |
| `external` | none | none |

Only the pins of the resolved method are declared, so an instance lock needs
the entries of its own method only. `seed.json` holds all of them; `dotsteward
init` merges it into the instance lock.

## Verification status

- Self-update switch: Verified on 2026-10-06 from the setup documentation
  <https://code.claude.com/docs/en/setup> ("Disable auto-updates",
  "Auto-updates"), the environment variable reference
  <https://code.claude.com/docs/en/env-vars> (`DISABLE_AUTOUPDATER`,
  `DISABLE_UPDATES`), and by a run of the native build 2.1.285 for
  `linux-x64` in a temporary `HOME`, without any activation:
  - the build downloaded from the release URL matched the size and
    SHA-256 of the release's `manifest.json` and printed
    `2.1.285 (Claude Code)`;
  - installed as a regular file at `~/.local/bin/claude`, `claude update`
    reported an update to a newer version, wrote it to
    `~/.local/share/claude/versions/` and left the regular file in place:
    `claude --version` still printed `2.1.285 (Claude Code)`;
  - with `"env": { "DISABLE_AUTOUPDATER": "1" }` in `~/.claude/settings.json`,
    `claude doctor` reported `Auto-updates: disabled (set by env:
    DISABLE_AUTOUPDATER)`, and `claude update` still worked;
  - with `DISABLE_UPDATES` set to `1` (in `settings.json` or the
    environment), `claude update` refused to update and `claude doctor`
    reported `Auto-updates: disabled (set by env: DISABLE_UPDATES)`.

  Decision: the switch exists, but dotsteward does not set it. The method
  keeps `policy = "at-least"` (a newer build is kept, never downgraded),
  consistent with `native_application_updates = true`; the user decides
  about background updates in `claude-settings` (see Self-update).
- darwin build: the release manifest lists `darwin-arm64` with its own size
  and checksum (verified on 2026-10-06 from the 2.1.285 `manifest.json`); a
  darwin run is not verified on this machine.
- DEB: the stable APT index lists `claude-code` `2.1.285-1` for `amd64` with
  the size and SHA-256 of the seed (verified on 2026-10-06 from
  `dists/stable/main/binary-amd64/Packages`); the DEB install itself is not
  verified on this machine (it needs root and runs in CI and the VM).
