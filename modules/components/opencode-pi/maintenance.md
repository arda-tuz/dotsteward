# opencode-pi maintenance

Update notes for `dotsteward-update`. Move the pins only in an explicit maintenance run, and validate the candidate with the agents checks of this component (`README.md`, "Checks") on a real installation.

## Pi

- Canonical source: https://github.com/earendil-works/pi. Official npm package: `@earendil-works/pi-coding-agent`. Do not return to an older package scope.
- For a stable candidate, verify together: the npm integrity, the object ID of the official `v<version>` tag (`agent_tools.pi.tag_revision`), the MIT license and the `engines.node` lower bound (`node_engine`); the package builds with `nodejs_22`.
- The deterministic Nix build does not install the npm tarball while the internal workspace packages of its published shrinkwrap lack integrities. Refresh in one change: the official source tag, `source_nix_sha256`, `npm_dependencies_nix_sha256` (from the upstream workspace lock), the model data tarball of `@earendil-works/pi-ai` of the same version (`model_data_url`, `model_data_nix_sha256`), `nix_packages.pi.{expected,resolved}` and the skills lock `nix_tools.pi` (`dotsteward pins sync` writes the derived values).
- The npm dependency hash depends on the fetcher of the nixpkgs in use; after a nixpkgs update, build `pi` and take the reported hash when it changed.
- The acceptance is not only `pi --version`: `pi --help` must list `--offline` and `--no-skills`, `pi auth check --help` must list `--json` and `--no-refresh`, and the offline isolated RPC `get_commands` session must list every shared skill.
- The workspace copy loop in `pi-package.nix` names every internal workspace package; when upstream adds or removes one, update the list (a missing entry leaves a dangling link that the build removes, so the program fails at run time, not at build time).
- Do not disable Pi's own update check or telemetry defaults through configuration; the Nix-managed version moves only through maintenance.
- Pi's user state below `~/.pi/agent` (credentials, settings, sessions, trust, npm and git caches) is never tracked.

## OpenCode

- Canonical source: https://github.com/anomalyco/opencode, releases tagged `v<version>`.
- Refresh both release pins in one change, at the same version: `agent_tools.opencode` (`opencode-linux-x64.tar.gz`) and `agent_tools.opencode-darwin` (`opencode-darwin-arm64.zip`), each with `url`, `size`, `sha256` and the tag's commit as `source_revision`. Verify the digest of the downloaded asset, not only the one the release page reports, and that the archive still holds the single member `opencode`.
- The policy is `at-least` and OpenCode updates itself (`native_auto_updates = true`): the pin is a floor, never a downgrade.
- Do not read the full skill catalog from `opencode debug skill`: its output can be truncated at 64 KiB. The `opencode-skill-api` check reads the local `/skill` API of a temporary `opencode serve --pure` and stops it; after a skill update, confirm that it sees every expected name.
- Re-check the configuration path (`~/.config/opencode/opencode.json`) against the OpenCode documentation when OpenCode changes its configuration loading, and update the verification record in `README.md`.
