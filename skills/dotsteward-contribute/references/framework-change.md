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
| Privacy scanner | `cli/lib/privacy.sh`, `.githooks/pre-push` (`privacy/policy.toml` and `privacy/allowlist.txt` change only in their own, manually reviewed pull request: `contribute check` stops on a branch that changes them) | `tests/privacy/`, `tests/hooks/` |
| Schemas and docs | `schema/*.json`, `docs/*.md`, `README.md` | `tests/static/` |

Nix checks are files too: `nix/checks/<name>.nix`, discovered by name; most wrap test directories with `mkTestCheck`, so a new test file under an existing directory is picked up without a Nix edit.

## The reproduction test

- A test is a file `tests/<area>/test-<name>.sh`, discovered by `tests/run.sh`. It runs in a fresh bash with a temporary `HOME`, `TMPDIR` and git identity and the assertions of `tests/lib/assert.sh`.
- Test the behaviour the user met, end to end: run the real command on a synthetic instance or fixture, with stubs only for the network and for programs outside the framework.
- Fixtures are synthetic: example names, `example.com` style addresses, `/home/user` style paths. Build secret-shaped strings at run time with `fake_secret` from `tests/lib/harness.sh`; never paste one into a file.
- Prove it fails with `dotsteward contribute check --expect-fail tests/<area>/test-<name>.sh` (the path is relative to the clone), then commit it alone with `dotsteward contribute commit -m "test(<area>): ..." --test`.

## The fix

- Fix the cause for every user; a preference of one user is a configuration value, an overlay or a private component instead (`references/classification.md`).
- English, ASCII only. No personal data of anyone, no application name outside the public catalog, nothing copied from the instance; the instance-leak scan of `check` searches the new commits for the instance's user, home, remote, host, private component, settings and skill names.
- Fix every lint error, failing test or flaky test you meet in the clone, even when the fix did not cause it. Bash stays clean under `shellcheck`; Nix is formatted with `nix fmt`.
- A changed framework skill needs a fresh manifest: `bash tools/gen-skills-manifest.sh` in the clone, committed with the skill.
- Docs describe policy, not version numbers. No changelog file is written; the release notes are generated from the commit history.

## The release version

`VERSION` holds the release the commits are based on, and changes only in a release commit. A fix or a feature keeps it: the next release bundles every commit since the last one (release trains). `publish` refuses a `VERSION` that is neither that base release nor exactly the next one.

When the run should end with a release (the user asks for one, or the change must reach other users now), add a release commit after the fix commit:

1. Fetch the release tags of the publish target, so the clone sees the newest release (in fork mode fetch the `upstream` remote as well):

   ```bash
   git -C "$clone" fetch --quiet --tags origin
   ```

2. Let the tool write the next version into `VERSION` and every copy of it (the plugin manifests, the marketplace and the `dotsteward` tag of `template/flake.nix`) and commit exactly those files as the release commit, `chore(release): X.Y.Z` with UTC dates:

   ```bash
   (cd "$clone" && bash tools/version.sh bump --commit)
   ```

   The next version follows semantic versioning from the conventional commits since the release the branch is based on, after the newest release tag: any `feat` makes the next minor, anything else the next patch; without any tag the history counts from `0.0.0`. A breaking change (`type!:` or a `BREAKING CHANGE:` footer) makes the next major, which only the user decides: the tool refuses it without `bash tools/version.sh bump --major --commit`, and the release then needs `dotsteward contribute release --major`.

The copies of `VERSION` are never edited by hand: `bash tools/version.sh sync` writes them, and the framework gate fails on a stale one.

## Commits

- Two commits on the run's branch: `test(<area>): ...` with the reproduction (it fails), then `fix(<area>): ...` or `feat(<area>): ...` with the change (it passes), plus the `chore(release): X.Y.Z` release commit when the run ends with a release. Further fixes after a red gate, trial or CI are new commits; nothing is amended after `check` passed.
- Commit with `dotsteward contribute commit -m SUBJECT [-m PARAGRAPH...]`, adding `--test` for the reproduction: it stages everything and commits with the identity `dotsteward contribute setup` set in the clone, the GitHub login and its noreply address (`<id>+<login>@users.noreply.github.com`), and with UTC dates, whatever the environment says. The subject is a conventional commit, `TYPE(<area>): <what changed>`. The release commit of `tools/version.sh bump --commit` meets the same rules.
- Commit messages carry no attribution trailers: no co-author lines, no agent session links, no generated-by lines, and no trailer block of any kind. `contribute commit` and the clone's commit-msg hook refuse them before the commit exists, and the clone's pre-commit hook refuses dates outside UTC; the pre-push hook, CI and the framework gate refuse both later.
