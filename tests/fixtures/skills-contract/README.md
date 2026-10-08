# Skill contract fixtures

Synthetic data for `tests/skills` (skill contract checks C1-C10).

- `classification.md`: the canonical `references/classification.md`. Every framework skill
  (`dotsteward-maintain`, `dotsteward-update`, `dotsteward-contribute`) ships these exact bytes
  (check C7); change this file and the three copies together.
- `example-skill/`: a skill that satisfies every check when completed by
  `tests/skills/selftest/helpers.sh` (which adds `LICENSE` from the repository root and
  `references/classification.md` from the file above). The self-tests mutate copies of it.
- `cli/dotsteward`: a stand-in CLI for the self-tests. It answers `--help` from `cli/help/` and
  `context --json` with the conventional commit types in `SC_FAKE_CONVENTIONAL_TYPES`.
- `instance/workstation.toml`: the synthetic instance whose `dotsteward context --json` supplies
  the CLI's conventional commit types to the real skill tests (check C6).
