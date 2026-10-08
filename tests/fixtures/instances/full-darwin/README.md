# Full darwin fixture instance

The instance `dotsteward init` writes for a new user on a Mac with
all six catalog components (`shell`, `herdr`, `claude-code`, `codex`,
`opencode-pi`, `vscode`) on `aarch64-darwin`, and two synthetic private
components: `example-app` (method `nix`, a packaged and checked command) and
`example-term` (method `official-binary` by default, which it supports only on
Linux, so `method_by_platform` selects `nix` on darwin; active in the
`workstation` profile only). The components resolve to their darwin methods:
`vscode` installs the official archive into `~/Applications` (`app-archive`),
`claude-code`, `codex` and `opencode-pi` use the darwin release assets.

It is the full Linux fixture (`../full`) with `nix.systems` and the
`example-term` method changed: `versions.lock.json` (the template lock merged
with the seed of every catalog component, which carries the pins of both
platforms, plus the `example-app` pin), `agent/skills.lock.json`, the settings
buffer, `flake.nix` and `flake.lock` (never evaluated: they exist for the
offline pins check of `flake_inputs`) are the same files.

`nix/checks/darwin-eval.nix` lays this directory over the framework
`template/`, adds the `.dotsteward/` mirrors rendered from the evaluated
instance (they contain values of the framework under test, so they are never
committed here) and evaluates every check of the instance on `aarch64-darwin`
from `x86_64-linux` with a stand-in `herdr` input: the derivations are
instantiated, never built.
