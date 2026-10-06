Synthetic seeds for the seed merge golden of tests/instance/init/test-seeds.sh
(SPEC 5.6). They replace the shell and codex seeds in a copy of the framework:

- `shell.json` and `codex.json` share `agent_tools.shared` with equal leaves
  (a list among them), which merges; `codex.json` adds keys to sections the
  template lock (`nix_packages`) and `shell.json` (`agent_tools`) start, and
  a new section (`desktop_packages`); both add to the skills lock.
- `versions.golden.json` and `skills.golden.json` are the composed locks
  without the template's own sections and values (`schema_version`,
  `generated_at`, `policy`, `nix`, `flake_inputs`, `nix_packages.tomlkit`,
  `expected_skill_count`, `layout`, `skills`), in the order init writes
  them: the template's keys first, then each seed's new keys in catalog
  order.
