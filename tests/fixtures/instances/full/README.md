# Full Linux fixture instance

The instance `dotsteward init` writes for a new user with all six
catalog components (`shell`, `herdr`, `claude-code`, `codex`, `opencode-pi`,
`vscode`) on `x86_64-linux`, and two synthetic private components:
`example-app` (method `nix`, a packaged and checked command) and
`example-term` (method `official-binary`, active in the `workstation` profile
only).

`versions.lock.json` is the template lock merged with the seed of every
catalog component plus the `example-app` pin;
`agent/skills.lock.json` holds the mirrors the `opencode-pi` rules and probes
read. `flake.nix` and `flake.lock` are never evaluated: they exist for the
offline pins check of `flake_inputs`. The settings buffer tracks one key in a
settings target of each component that declares one.

`nix/checks/template-full.nix` lays this directory over the framework
`template/`, adds the `.dotsteward/` mirrors rendered from the evaluated
instance (they contain values of the framework under test, so they are never
committed here), builds every check of the instance with a stand-in `herdr`
input and runs the probe registry of the check profile against the built
generation.
