# Testing

dotsteward changes real machines, so every behaviour is covered by a test
that runs the real code in a disposable environment. This page explains
the rules, the harness, where each suite runs and how to add a test.

## Rules

- **Tests first.** A change lands as two commits: `test(<area>): ...` adds
  the tests and fixtures, and the suite fails; `feat(<area>): ...` or
  `fix(<area>): ...` makes it pass. A reviewer can check out the first
  commit and see the failure.
- **Bugs start with a reproduction**: an end-to-end or regression test that
  fails the way the user saw it, before any fix.
- **Black box.** Tests run the real CLI and engines in a temporary home
  with stub executables, local bare Git remotes and a local HTTP server,
  not mocked functions.
- **No activation on a developer machine.** Suites never change the real
  home directory or the running system; real activation happens only on
  disposable CI runners and virtual machines.
- **Lint and flakiness are bugs.** Every shell file is clean under the
  pinned `shellcheck`; a `# shellcheck disable=` needs a reason on the same
  line. A flaky test is fixed, never retried away.
- **Synthetic data only.** Fixtures use invented users, paths and
  applications ([privacy.md](privacy.md)).

## Running tests

```sh
bash tests/run.sh                          # every fast suite
bash tests/run.sh tests/engines/settings   # one directory
bash tests/run.sh tests --only pins        # files whose path matches *pins*
nix flake check -L                         # every suite in the build sandbox
```

`tests/run.sh` finds every `test-*.sh` below the given paths (default
`tests/`), runs each file in a fresh bash process, prints `PASS <file>` or
`FAIL <file>: <message>` with the file's output, and exits 1 when any file
failed or none was found. Directories named `fixtures` are never searched.
`tests/ci`, `tests/host`, `tests/channels` and `tests/vm` run only when
named explicitly. `DS_TEST_TIMEOUT` (seconds, default 900) bounds each
file.

## The harness

Each test file runs with `tests/lib/harness.sh` and `tests/lib/assert.sh`
loaded, under `set -Eeuo pipefail`, in its own temporary root:

- `DS_REPO_ROOT` is the framework checkout under test (read-only for
  tests), `DS_TEST_ROOT` the temporary root, removed when the test exits;
- `HOME` and `TMPDIR` point inside the root, the user is the synthetic
  `dotsteward-test`, `TZ=UTC` and the C locale apply;
- Git reads only a temporary global configuration with a synthetic
  identity; every `XDG_*`, `GIT_*`, `DOTSTEWARD_*` and application variable
  of the host is removed, and so are the SSH agent and GitHub credentials,
  so a test can never reach a real remote with your identity;
- platform facts (`/etc/shells`, `os-release`, the user database, macOS
  version) come from synthetic files through the `DOTSTEWARD_*` injection
  points.

Register cleanup with `ds_defer`; never replace the `EXIT` trap.

### Assertions

| Function | Checks |
| --- | --- |
| `assert_eq` | two strings are equal |
| `assert_contains` | a string contains a substring |
| `assert_not_contains` | a string does not contain a substring |
| `assert_exit` | a command exits with a status; its output lands in `DS_STDOUT` and `DS_STDERR` |
| `assert_file_mode` | a file has a mode |
| `assert_symlink_to` | a path is a symlink to a target |
| `assert_calls` | the stub call log matches expected calls |
| `assert_call_count` | a stub was called a number of times |
| `assert_json` | a `jq` expression is true for a JSON file |

`ds_fail MESSAGE` fails the test directly.

### Stubs, remotes and downloads

`tests/lib/stubs/` holds one executable per external command the framework
calls (`sudo`, `apt-get`, `dpkg`, `curl`, `gh`, `nix`, the catalog
applications and the synthetic `example-app` and `example-term`, among
others). `ds_use_stubs` puts them first on `PATH`; every call is appended
to `DS_CALL_LOG`, and `ds_stub_set`, `ds_stub_route` and
`ds_stub_override` script their answers. `tests/lib/bare-remote.sh` and
`tests/lib/fakessh.sh` provide local bare Git remotes behind a fake SSH
transport, and `tests/lib/httpfix.py` serves fixture files over HTTP for
downloads and `pins latest` adapters.

### Fixtures

`tests/fixtures/` holds synthetic instances (a minimal one, a full one with
every catalog component and two private components, a darwin one), lock
files with one mutation per failure class, package indexes, vendor
manifests, settings buffers and skill trees. Nothing in them belongs to a
real person.

## Suites

| Directory | Covers | Runs in |
| --- | --- | --- |
| `tests/skeleton` | repository files, dispatcher, runner, harness core | `checks.skeleton` |
| `tests/harness` | the stubs, fixtures and fake remotes themselves | `checks.harness` |
| `tests/privacy` | the scanner | `checks.privacy` |
| `tests/hooks` | the pre-push hook | outside the sandbox (needs a writable bare remote) |
| `tests/cli` | CLI library, context, gate, update, bootstrap, rebuild, methods, launcher, E2E runner | `checks.cli-*` |
| `tests/engines` | the pins and settings engines | `checks.pins-*`, `checks.settings*` |
| `tests/agents`, `tests/probes` | the agents installer and the probe runner | `checks.agents`, `checks.probes` |
| `tests/nix` | the Nix library, core modules, instances and every catalog component | `checks.nix-*`, `checks.component-<name>`, `checks.darwin-eval` |
| `tests/static` | framework static contracts and these docs | `checks.static` |
| `tests/instance` | the template and `dotsteward init` | `checks.init`, `checks.template-*` |
| `tests/skills` | the skill contract | `checks.skills` |
| `tests/contribute` | the contribution flow against local bare remotes | `checks.contribute*` |
| `tests/host` | an instance built with real Nix in a temporary home, without activation | locally and in CI |
| `tests/ci` | clean-machine install and the macOS smoke test with real activation | GitHub Actions only |
| `tests/channels` | installing `dotsteward-init` through every channel | GitHub Actions only |
| `tests/vm` | the virtual machine harness | its self-test locally and in CI (`ci.yml`); VMs only on request |

`tests/lib` holds the harness itself and `tests/fixtures` the shared data.

Each `nix/checks/<name>.nix` is one sandboxed check, discovered by file
name. Most are a single
`(dsLib.mkCli pkgs).mkTestCheck { name = "..."; paths = [ "tests/..." ]; }`,
which runs `tests/run.sh` on those paths in a writable copy of the source
with the CLI toolchain on `PATH`. Nix tests evaluate against an isolated store
inside the test root, so they behave the same on a laptop and in the
sandbox.

## Continuous integration

| Workflow | What it runs |
| --- | --- |
| `ci.yml` | shellcheck, actionlint, Python syntax and the VM harness self-test (`tests/vm/selftest.sh`, no VM boots); `nix flake check -L`; the hook tests |
| `privacy.yml` | the privacy scans ([privacy.md](privacy.md#where-scans-run)) |
| `clean-install.yml` | a fresh Ubuntu runner set up end to end through `bootstrap.sh`, switched, checked, carried to a second home and rolled back |
| `macos-smoke.yml` | a real Mac: stage 0, a new darwin instance, build, switch and end-to-end checks; manual only |
| `channels.yml` | the three distribution channels of `dotsteward-init` |

## Adding a test

1. Put a `test-<what>.sh` file in the suite of the code it covers; it is
   discovered by name, so no list needs editing.
2. Start it with `# shellcheck shell=bash` and a comment that states the
   contract it checks.
3. Build inputs in `DS_TEST_ROOT`, run the real command with `assert_exit`,
   and assert on its output, files and the stub call log.
4. Watch it fail, commit it as `test(<area>): ...`, then make it pass.
5. When the suite runs in the sandbox, it already belongs to a check; a new
   suite gets its own `nix/checks/<name>.nix`.
