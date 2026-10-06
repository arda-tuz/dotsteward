# Changing the framework

How to write the reproduction and the fix in the framework clone of a run (`.clone` of `dotsteward contribute mode --json`). The clone's own `CONTRIBUTING.md` is the authority on style; read it first, then only the files the change touches (`git grep -n` finds the rest).

## Where things live

| Area | Paths | Tested by |
| --- | --- | --- |
| CLI command `dotsteward <sub>` | `cli/commands/<sub>.sh` (discovered by name; the first `# summary:` line is its help line), shared code in `cli/lib/*.sh`, Python helpers in `cli/python/dotsteward_cli/` | `tests/cli/`, `tests/contribute/`, `tests/hooks/`, `tests/privacy/` |
| Engines | `engines/pins/` (the pins engine), `engines/local-maintained-files/` (the settings buffer) | `tests/engines/` |
| Nix library and Home Manager modules | `lib/*.nix`, `modules/core/` | `tests/nix/`, `nix/checks/<name>.nix` |
| Catalog components | `modules/components/<name>/` (`default.nix`, `seed.json`, `README.md`, `maintenance.md`) | `nix/checks/`, `tests/nix/`, `tests/probes/` |
| Framework skills | `skills/<name>/` (`SKILL.md`, `agents/openai.yaml`, `LICENSE`, `references/*.md`), digests in the generated `skills/manifest.json` | `tests/skills/` |
| Template of new instances | `template/` (the stage-0 part of `template/bootstrap.sh` is generated from `cli/lib/stage0.sh` by `tools/gen-stage0.sh`) | `tests/instance/` |
| Privacy policy and scanner | `privacy/policy.toml`, `privacy/allowlist.txt`, `cli/lib/privacy.sh`, `.githooks/pre-push` | `tests/privacy/`, `tests/hooks/` |
| Schemas and docs | `schema/*.json`, `docs/*.md`, `README.md` | `tests/static/` |

Nix checks are files too: `nix/checks/<name>.nix`, discovered by name; most wrap test directories with `mkTestCheck`, so a new test file under an existing directory is picked up without a Nix edit.

## The reproduction test

- A test is a file `tests/<area>/test-<name>.sh`, discovered by `tests/run.sh`. It runs in a fresh bash with a temporary `HOME`, `TMPDIR` and git identity and the assertions of `tests/lib/assert.sh`.
- Test the behaviour the user met, end to end: run the real command on a synthetic instance or fixture, with stubs only for the network and for programs outside the framework.
- Fixtures are synthetic: example names, `example.com` style addresses, `/home/user` style paths. Build secret-shaped strings at run time with `fake_secret` from `tests/lib/harness.sh`; never paste one into a file.
- Prove it fails with `dotsteward contribute check --expect-fail tests/<area>/test-<name>.sh` (the path is relative to the clone), then commit it alone.

## The fix

- Fix the cause for every user; a preference of one user is a configuration value, an overlay or a private component instead (`references/classification.md`).
- English, ASCII only. No personal data of anyone, no application name outside the public catalog, nothing copied from the instance; the instance-leak scan of `check` searches the new commits for the instance's user, home, remote, host, private component, settings and skill names.
- Fix every lint error, failing test or flaky test you meet in the clone, even when the fix did not cause it. Bash stays clean under `shellcheck`; Nix is formatted with `nix fmt`.
- A changed framework skill needs a fresh manifest: `bash tools/gen-skills-manifest.sh` in the clone, committed with the skill.
- Docs describe policy, not version numbers. No changelog file is written; the release notes are generated from the commit history.

## The release version

Every fix is released as the next patch version, and `VERSION` is part of the fix: `publish` and `release` refuse a `VERSION` that differs from the tag they are about to create.

1. Find the newest release tag of the publish target; in fork mode list both `origin` and `upstream` and take the newest:

   ```bash
   git -C "$clone" ls-remote --tags --refs origin 'refs/tags/v*' | sed 's|.*refs/tags/v||' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
   ```

2. The next release is that version with the patch number plus one; with no tag at all it is `v0.0.1`.
3. Write the new version (without the `v`) into `VERSION`, then find every other file that carries the old version and move it too, for example the `dotsteward` tag of `template/flake.nix` and the plugin manifests:

   ```bash
   git -C "$clone" grep -n -F "$(git -C "$clone" show HEAD:VERSION)"
   ```

   The framework gate (`nix flake check` in `check`) fails when a file that must follow `VERSION` was missed.

## Commits

- Two commits on the run's branch: `test(<area>): ...` with the reproduction (it fails), then `fix(<area>): ...` or `feat(<area>): ...` with the change and the `VERSION` bump (it passes). Further fixes after a red gate, trial or CI are new commits; nothing is amended after `check` passed.
- The identity is the one `dotsteward contribute setup` set in the clone: the GitHub login and its noreply address (`<id>+<login>@users.noreply.github.com`). Dates are UTC: always commit with `TZ=UTC git commit`.
- Commit messages carry no attribution trailers: no co-author lines, no agent session links, no generated-by lines. The pre-push hook, CI and the framework gate refuse them.
