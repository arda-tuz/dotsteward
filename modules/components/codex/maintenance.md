# codex: maintenance notes

Notes for `dotsteward-update` and for framework maintainers.

## Release pins

Each platform of `nix.systems` whose method is `official-binary` has two pins
in `versions.lock.json`:

| Lock path | Asset |
| --- | --- |
| `agent_tools.codex.linux` | `codex-x86_64-unknown-linux-musl.tar.gz` |
| `agent_tools.codex.darwin` | `codex-aarch64-apple-darwin.tar.gz` |
| `agent_tools.codex-code-mode-host.linux` | `codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz` |
| `agent_tools.codex-code-mode-host.darwin` | `codex-code-mode-host-aarch64-apple-darwin.tar.gz` |

Each pin holds `version`, `url`, `size` and `sha256`. The component declares,
per pinned platform:

- a `download-pin` rule (`release-linux`, `release-darwin`): the URL must be
  `https://github.com/openai/codex/releases/download/rust-v{version}/<asset>`,
  the size a positive integer and the digest 64 hex digits; checked by
  `dotsteward pins check`;
- a `github-release` latest row (`repo = "openai/codex"`,
  `tag_prefix = "rust-v"`, the platform's asset) for the `github-release`
  latest adapter of the pins engine.

The helper pins declare the same two, plus a `derive` rule that ties their
version to the codex pin, once the lock has them; a lock without them stays
valid (README.md, "The helper").

## Updating

1. Take the newest stable release: a `rust-v<version>` tag that is neither a
   draft nor a prerelease (`alpha` and `beta` tags are prereleases).
2. For each pinned platform, set `version`, the URL of the platform's asset
   in that release, and the asset's `size` and `sha256`. GitHub publishes
   the asset digest (`sha256:<hex>`) in the release's assets list; download
   the archive once and compare its size and `sha256sum` with it before
   writing the pin.
3. All platforms and both assets move together: the pins of one lock carry
   one version. Write the helper's `version`, `url`, `size` and `sha256` in the
   same change; `pins sync` writes only its `version`, and the `download-pin`
   rule then asks for the URL.
4. Run `dotsteward pins check`, then a rebuild of a profile that enables
   codex: the installer downloads the new archive, verifies it and reads
   `codex-cli <version>` from the installed binary.

The `at-least` policy keeps a binary that updated itself to a newer version,
so a pin bump never downgrades a machine; it only raises the floor.

## When upstream changes

- New run-time files: compare `bin/` and the top of the standalone package
  (`codex-package-<target>.tar.gz`) and the checks of `release_dir_is_complete`
  in the official `install.sh` with what this component installs. A new
  executable that a session cannot do without is one more entry of
  `install.official-binary.companions` in `default.nix`, with its pins.
- Asset or member renamed: update `releases` in `default.nix` (assets and
  members per platform), the `download-pin` URLs follow from it. Re-run the
  component tests (`tests/nix/components/codex`).
- `codex --version` output changed: update `versionRegex` in `default.nix`.
- The helper gained a `--version` or lost `--help`: update
  `e2e-code-mode-host.sh`, which starts it with `--help`.
- Sigstore: the Linux release ships `codex-x86_64-unknown-linux-musl.sigstore`
  for the extracted binary; darwin ships none (README.md, "Verification").
  `pins apply` records and verifies it (docs/pins-engine.md, Authenticity).
  Re-check this when upstream starts signing the archives or the darwin
  binary (then `verify = "sha256+sigstore"` fits both platforms), and record
  the new result in README.md.
- Plugins: the hook relies on `codex plugin list --json` (an `installed`
  list with `pluginId`, `installed`, `enabled`, `version` and an optional
  local `source` with `path`), on `codex plugin add NAME@MARKETPLACE` and on
  the cache layout
  `${CODEX_HOME:-~/.codex}/plugins/cache/<marketplace>/<name>/<version>/.codex-plugin/plugin.json`,
  which it verifies before the local source, because Codex may leave the
  marketplace snapshot (`.tmp/marketplaces/<marketplace>`, the local source
  of a plugin at a marketplace's root) ahead of the listed version.
  A change in any of them needs `plugins.sh`, the `codex` test stub and
  `tests/nix/components/codex/test-plugins.sh` updated together. The
  re-reads of check mode (`relist_pauses` in `plugins.sh`) rely on Codex
  listing the plugins of a remote marketplace as missing, with a warning,
  when its remote catalog request fails
  (`tests/nix/components/codex/test-plugins-remote-catalog.sh`).
- Tracked plugins: an instance refreshes a plugin when its `git-compare`
  row is a review: read the changed paths of the marketplace, then move
  `observed_marketplace_revision` of the `trackAt` entry to the reported
  head and, with `minimumAt`, raise the minimum to the new plugin version.
  The validation and the rows come from `lib/plugin-tracking.nix`, shared
  with the claude-code component.
