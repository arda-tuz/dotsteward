# opencode-pi

The OpenCode and Pi coding agents: both discover the shared skills in `~/.agents/skills`, and Pi reads the instance's agent rules.

Enable it in `workstation.toml`:

```toml
[components.opencode-pi]
enable = true
# method = "external"                       # OpenCode installed by you
# method_by_platform = { darwin = "external" }
```

## What it installs

| Part | Linux (`x86_64-linux`) | darwin (`aarch64-darwin`) |
| --- | --- | --- |
| OpenCode, method `official-binary` (default) | release asset `opencode-linux-x64.tar.gz`, pin `agent_tools.opencode` | release asset `opencode-darwin-arm64.zip`, pin `agent_tools.opencode-darwin` |
| OpenCode, method `external` | `opencode` on `PATH`, at least the pinned version | same |
| Pi | Nix package `pi`, built from source | same (evaluated, see Verification) |

**OpenCode.** `dotsteward agents install` downloads the official release archive of the platform from the GitHub releases of `anomalyco/opencode` (tag `v<version>`), verifies its size and SHA-256 against the release pin in `versions.lock.json`, and installs its single member `opencode` as `~/.local/bin/opencode`. The policy is `at-least`: a binary that updated itself to a newer version is kept, an older or missing one is replaced (the previous file is backed up first), and a symbolic link at the destination is refused. `dotsteward agents check` only compares the installed version with the pin. The same applies in `adopt` and `fresh` profiles: the install is user level. With `method = "external"` nothing is downloaded; `opencode` must be on `PATH` and at least the pinned version.

**Pi.** The instance package `pi` (`package.nix`, `pi-package.nix`) builds the Pi coding agent from the official source tag of `earendil-works/pi`, pinned by `agent_tools.pi`: the source hash, the npm dependency hash of the upstream workspace lock, and the model data of the `@earendil-works/pi-ai` package of the same version. The published npm tarball is not used because its shrinkwrap lacks the integrities of the internal workspace packages. The build runs `npm run build:offline` in the coding-agent workspace with install scripts disabled, replaces the workspace links with copies, and wraps `pi` with the ripgrep and fd packages of nixpkgs on its `PATH`. No `PI_*` variable is set, so Pi's own update check and telemetry defaults are untouched. The package is added to `home.packages` wherever the component is active (enabled, in the profile, on the platform), whatever the OpenCode method is, and `checks.<system>.pi` of the instance builds it, including its version check. An instance may replace it through `extraPackages`.

## Files and settings

- Agent rules: `~/.pi/agent/AGENTS.md` links to the instance's agent rules file (`[agent_rules] source`). It is a managed link (checked by E2E, removed by rollback) and a bootstrap backup path.
- Settings target `opencode`: `~/.config/opencode/opencode.json` on both platforms, format `jsonc` (OpenCode accepts JSON with comments), created with mode `0644` when a buffer entry applies, backed up before the first write. Nothing is reloaded: OpenCode reads the file at start.
- Pi's user state below `~/.pi/agent` (credentials, settings, sessions, trust, npm and git caches) is never tracked.

## Checks

Run by `dotsteward agents check` (and after `agents install`), in this order:

1. Commands: `opencode` and `pi` are on `PATH`.
2. Probes, with `PI_OFFLINE=1`: `pi --version` equals the skills lock mirror `nix_tools.pi`; `pi --help` lists `--offline` and `--no-skills`; `pi auth check --help` lists `--json` and `--no-refresh`.
3. `opencode-version`: `opencode --version` prints a version.
4. `opencode-skill-api`: a temporary `opencode serve --pure` on a free loopback port answers `GET /skill`; every expected skill must be listed with a location that resolves to a `SKILL.md` below `~/.agents/skills` (outside `.system`); OpenCode also reads `~/.claude/skills`, whose links into that root may be the listed location. The server is stopped before the check ends. The API is used because the output of `opencode debug skill` is truncated at 64 KiB.
5. `pi-rpc`: one offline RPC session (`pi --mode rpc --no-session --no-extensions --no-prompt-templates`, `PI_OFFLINE=1`, a fresh temporary `PI_CODING_AGENT_DIR` removed afterwards) answers `get_commands`; every expected skill must be among the skill commands.

The expected skills are the entries of the instance skills lock and the framework skills of the instance manifest. A skill one agent does not see fails the check with its name.

## Lock paths

| Path | Content | Pin rules |
| --- | --- | --- |
| `agent_tools.pi` | `package`, `version`, `official_tag`, `tag_revision`, `source_nix_sha256`, `npm_dependencies_nix_sha256`, `model_data_url`, `model_data_nix_sha256` | `official_tag` is `v<version>`, `model_data_url` is the pi-ai tarball of `version`, formats of the revision and the hashes |
| `nix_packages.pi` | `expected`, `resolved` | `expected` equals `agent_tools.pi.version`; `resolved` is mirrored to the skills lock `nix_tools.pi` |
| `agent_tools.opencode` | Linux release: `minimum_version`, `source_revision`, `url`, `size`, `sha256`, `native_auto_updates` | download pin of `opencode-linux-x64.tar.gz` of `minimum_version`; mirrored to the skills lock `release_tools.opencode` |
| `agent_tools.opencode-darwin` | darwin release: `minimum_version`, `source_revision`, `url`, `size`, `sha256` | download pin of `opencode-darwin-arm64.zip`; `minimum_version` follows the Linux pin when both platforms are pinned |

Only the release pins of the platforms in `nix.systems` whose OpenCode method is `official-binary` are read and checked; `seed.json` holds all of them. The skills lock mirrors need their parent objects (`release_tools.opencode`, `nix_tools`) in `agent/skills.lock.json`; `dotsteward pins sync` fills the values but never creates entries. `dotsteward pins latest` follows the npm package `agent_tools.pi.package` and the GitHub releases of `anomalyco/opencode` (one row per release pin).

## Verification

Catalog facts of this component:

- OpenCode configuration path: verified on 2026-10-06 from the OpenCode documentation (https://opencode.ai/docs/config/, section "Global"): the global configuration is `~/.config/opencode/opencode.json`, the same path on Linux and macOS, in JSON or JSONC.
- OpenCode release assets: verified on 2026-10-06 from the GitHub release `v1.18.34` of `anomalyco/opencode`: `opencode-linux-x64.tar.gz` and `opencode-darwin-arm64.zip` each hold the single member `opencode`; sizes and SHA-256 digests in `seed.json` match the downloaded assets.
- Pi on Linux: verified on 2026-10-06 by building the package from `seed.json` with the framework's nixpkgs on `x86_64-linux` (install check `pi --version` passed).
- Pi on darwin: verified on 2026-10-06 from the evaluation of the Pi derivation for `aarch64-darwin` with the framework's nixpkgs (it evaluates and is available on the platform); not built, since no darwin builder took part. The Pi part therefore stays on both platforms.
