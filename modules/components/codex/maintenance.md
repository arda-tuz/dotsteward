# codex: maintenance notes

Notes for `dotsteward-update` and for framework maintainers.

## Release pins

Each platform of `nix.systems` whose method is `official-binary` has one pin
in `versions.lock.json`:

| Lock path | Asset |
| --- | --- |
| `agent_tools.codex.linux` | `codex-x86_64-unknown-linux-musl.tar.gz` |
| `agent_tools.codex.darwin` | `codex-aarch64-apple-darwin.tar.gz` |

Each pin holds `version`, `url`, `size` and `sha256`. The component declares,
per pinned platform:

- a `download-pin` rule (`release-linux`, `release-darwin`): the URL must be
  `https://github.com/openai/codex/releases/download/rust-v{version}/<asset>`,
  the size a positive integer and the digest 64 hex digits; checked by
  `dotsteward pins check`;
- a `github-release` latest row (`repo = "openai/codex"`,
  `tag_prefix = "rust-v"`, the platform's asset) for the `github-release`
  latest adapter of the pins engine.

## Updating

1. Take the newest stable release: a `rust-v<version>` tag that is neither a
   draft nor a prerelease (`alpha` and `beta` tags are prereleases).
2. For each pinned platform, set `version`, the URL of the platform's asset
   in that release, and the asset's `size` and `sha256`. GitHub publishes
   the asset digest (`sha256:<hex>`) in the release's assets list; download
   the archive once and compare its size and `sha256sum` with it before
   writing the pin.
3. All platforms move together: the pins of one lock carry one version.
4. Run `dotsteward pins check`, then a rebuild of a profile that enables
   codex: the installer downloads the new archive, verifies it and reads
   `codex-cli <version>` from the installed binary.

The `at-least` policy keeps a binary that updated itself to a newer version,
so a pin bump never downgrades a machine; it only raises the floor.

## When upstream changes

- Asset or member renamed: update `releases` in `default.nix` (asset and
  member per platform), the `download-pin` URL follows from it. Re-run the
  component tests (`tests/nix/components/codex`).
- `codex --version` output changed: update `versionRegex` in `default.nix`.
- Sigstore: the Linux release ships `codex-x86_64-unknown-linux-musl.sigstore`
  for the extracted binary; darwin ships none (README.md, "Verification").
  Re-check this when the official-binary method gains `sha256+sigstore`
  support or upstream starts signing the archives or the darwin binary, and
  record the new result in README.md.
- Plugins: the hook relies on `codex plugin list --json` (an `installed`
  list with `pluginId`, `installed`, `enabled`, `version` and an optional
  local `source` with `path`), on `codex plugin add NAME@MARKETPLACE` and on
  the cache layout
  `${CODEX_HOME:-~/.codex}/plugins/cache/<marketplace>/<name>/<version>/.codex-plugin/plugin.json`.
  A change in any of them needs `plugins.sh`, the `codex` test stub and
  `tests/nix/components/codex/test-plugins.sh` updated together.
