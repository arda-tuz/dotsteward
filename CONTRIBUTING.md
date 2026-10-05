# Contributing to dotsteward

Thank you for helping. dotsteward manages other people's machines, so every
change is held to the same bar: tested, reviewed, reproducible.

## Ground rules

- **Tests first.** A change lands as two commits: `test(<area>): ...` adds
  the tests (and fixtures) and fails; `feat(<area>): ...` or
  `fix(<area>): ...` makes them pass. A bug fix starts with a test that
  reproduces the bug.
- **Conventional commits.** Types: `feat`, `fix`, `test`, `refactor`,
  `docs`, `chore`, `ci`, `build`, `perf`.
- **No changelog file.** Release notes are generated from the commit history.
- **Lint and flakiness are bugs.** Fix any lint error, failing test or flaky
  test you meet, even when it is not yours.
- **English only**, ASCII text in every file.

## Privacy

The framework never contains personal data: no real names, e-mail addresses,
home paths, host names or tokens, and no application names outside the public
catalog. Tests use synthetic fixtures only; secret-shaped strings are built at
run time with `fake_secret` from `tests/lib/harness.sh`. Commits use your
GitHub noreply address and UTC dates:

```sh
git config user.email "<id>+<login>@users.noreply.github.com"
TZ=UTC git commit
```

## Layout and discovery

- CLI commands are files: `cli/commands/<name>.sh`, discovered by the
  dispatcher `cli/dotsteward`. The first `# summary:` line is the help text.
- Nix checks are files: `nix/checks/<name>.nix`, discovered by
  `nix/outputs.nix`. Each is a function
  `{ self, pkgs, system, lib, dsLib }` returning a derivation; most use
  `(dsLib.mkCli pkgs).mkTestCheck { name = "..."; paths = [ "tests/..." ]; }`.
- Tests are files: `tests/**/test-*.sh`, discovered by `tests/run.sh`.

## Tests

```sh
bash tests/run.sh                        # all fast suites
bash tests/run.sh tests/skeleton         # one suite
bash tests/run.sh tests --only dispatch  # filter by path glob
nix flake check -L                       # sandboxed checks
```

Each test file runs in a fresh bash process with `set -Eeuo pipefail`, a
temporary `HOME`, `TMPDIR` and git identity, `TZ=UTC`, and the assertions
from `tests/lib/assert.sh` (`assert_eq`, `assert_contains`,
`assert_not_contains`, `assert_exit`, `assert_file_mode`,
`assert_symlink_to`, `assert_calls`, `assert_json`).

## Style

- Bash: `set -Eeuo pipefail`, clean under `shellcheck`; a
  `# shellcheck disable=` needs a reason on the same line.
- Nix: formatted with nixfmt (RFC style):
  `git ls-files -z '*.nix' | xargs -0 nix fmt --`.
- Output: `[dotsteward] message` on stdout, `[dotsteward] WARNING: ...` and
  `[dotsteward] ERROR: ...` on stderr; machine-readable output goes to stdout
  as one JSON document.
