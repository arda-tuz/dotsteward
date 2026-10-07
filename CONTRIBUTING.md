# Contributing to dotsteward

Thank you for helping. dotsteward manages other people's machines, so every
change is held to the same bar: tested, reviewed, reproducible.

The easiest way to contribute is from your own workstation: the
`dotsteward-contribute` skill and `dotsteward contribute` reproduce a
problem, fix it in a clone of the framework, try it on your machine,
publish it and upgrade your instance ([docs/contribute.md](docs/contribute.md)).
The rules below apply however you work.

## Ground rules

- **Tests first.** A change lands as two commits: `test(<area>): ...` adds
  the tests (and fixtures) and fails; `feat(<area>): ...` or
  `fix(<area>): ...` makes them pass. A bug fix starts with a test that
  reproduces the bug. See [docs/testing.md](docs/testing.md).
- **Conventional commits.** Types: `feat`, `fix`, `test`, `refactor`,
  `docs`, `chore`, `ci`, `build`, `perf`.
- **No changelog file.** Release notes are generated from the commit history.
- **Lint and flakiness are bugs.** Fix any lint error, failing test or flaky
  test you meet, even when it is not yours.
- **English only**, ASCII text in every file.
- **Generic changes only.** The framework serves every user: no value of
  your own instance, and no application outside the catalog. A tool only
  you use belongs in your instance as a private component
  ([docs/writing-components.md](docs/writing-components.md)).

## Privacy

The framework never contains personal data: no real names, e-mail addresses,
home paths, host names or tokens, and no application names outside the public
catalog. Tests use synthetic fixtures only; secret-shaped strings are built at
run time with `fake_secret` from `tests/lib/harness.sh`. Commits use your
GitHub noreply address and UTC dates, without generated trailers:

```sh
git config user.email "<id>+<login>@users.noreply.github.com"
git config core.hooksPath .githooks
TZ=UTC git commit
```

The pre-push hook scans every pushed commit and refuses to push without
your private denylist; [docs/privacy.md](docs/privacy.md) explains the
scanner, the denylist and the CI checks.

## Layout and discovery

- CLI commands are files: `cli/commands/<name>.sh`, discovered by the
  dispatcher `cli/dotsteward`. The first `# summary:` line is the help text.
- Nix checks are files: `nix/checks/<name>.nix`, discovered by
  `nix/outputs.nix`. Each is a function
  `{ self, pkgs, system, lib, dsLib }` returning a derivation; most use
  `(dsLib.mkCli pkgs).mkTestCheck { name = "..."; paths = [ "tests/..." ]; }`.
- Tests are files: `tests/**/test-*.sh`, discovered by `tests/run.sh`.
- Catalog components are directories: `modules/components/<name>/`,
  discovered by `nix/outputs.nix` ([docs/component-contract.md](docs/component-contract.md)).
- Generated files are regenerated, never edited by hand: `docs/cli.md`,
  `docs/catalog.md` and `docs/components/` by `tools/gen-docs.sh`,
  `skills/manifest.json` by `tools/gen-skills-manifest.sh`.

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
`assert_symlink_to`, `assert_calls`, `assert_call_count`, `assert_json`).
Never activate a Home Manager generation on your own machine to test a
change; real activation runs on CI runners and virtual machines.

## Style

- Bash: `set -Eeuo pipefail`, clean under `shellcheck`; a
  `# shellcheck disable=` needs a reason on the same line.
- Nix: formatted with nixfmt (RFC style):
  `git ls-files -z '*.nix' | xargs -0 nix fmt --`.
- Output: `[dotsteward] message` on stdout, `[dotsteward] WARNING: ...` and
  `[dotsteward] ERROR: ...` on stderr; machine-readable output goes to stdout
  as one JSON document.
- Docs: one H1 per page, fenced blocks that name a language, relative links
  that resolve, and only commands and options that exist; the docs tests in
  `tests/static` enforce it.

## Security

Report vulnerabilities privately, never in a public issue: see
[SECURITY.md](SECURITY.md).
