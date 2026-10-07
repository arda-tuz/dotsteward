# Pins engine

Every version a workstation uses is pinned in the instance's lock files.
The pins engine, `dotsteward pins`, proves that those files agree with each
other and with the rules the components declare, rewrites the values that
are derived from other values, and asks official sources for newer stable
releases. It contains no application names: everything specific comes from
component declarations ([component-contract.md](component-contract.md#pins)).

## Lock files

| File | Role |
| --- | --- |
| `versions.lock.json` | The single source of truth for versions, URLs, sizes and hashes. |
| `flake.lock` | The locked flake inputs; `flake_inputs` of the versions lock mirrors its root inputs. |
| `agent/skills.lock.json` | The vendored instance skills and their digests, plus the versions the agents installer needs. |

Both JSON lock files are written as `json.dumps(indent=2)` plus a final
newline, in insertion order, with values updated in place and atomic
writes. `generated_at` changes only when the content changes. The engine
never creates entries and never edits `flake.lock`, `flake.nix` or npm
package files.

Framework-owned sections of `versions.lock.json` are `schema_version`,
`generated_at`, `policy` ([update-policy.md](update-policy.md)), `nix` (the
Nix installer read by the first bootstrap), `flake_inputs` and
`nix_packages`. Every other section belongs to the components that declare
rules for it.

## Commands

```sh
dotsteward pins check            # every rule, offline
dotsteward pins check --nix      # also the versions Nix resolves
dotsteward pins sync             # rewrite derived values
dotsteward pins sync --skill NAME
dotsteward pins latest --out report.json
dotsteward sync                  # pins sync plus the .dotsteward/ mirrors
```

Exit codes: 0 consistent, 1 an inconsistency or a refusal, 2 a usage error
or broken input (no instance, an invalid rule, an unreadable lock file, a
failed Nix evaluation). `pins latest` exits 1 when any row is an error.
The gate runs `pins check`, so a red pin never reaches a published tree.

## Lock paths and templates

Rules and adapters address values with **lock paths**:

- `agent_tools.example-term.version` is a dot-separated path into
  `versions.lock.json` (the default, also written `versions:...`);
  `skills:release_tools.example.version` addresses the skills lock.
- A key that contains dots or other special characters is a JSON string:
  `feature_probes."example --version"`.
- A selector picks the first list element whose field matches:
  `skills:plugins[spec=example@market].revision`.
- A leading `.` makes the path relative to the rule's base object (`at`,
  or the current `for_each` entry).

A **template** is text with `{placeholder}` parts: `{key}` and `{value}` of
the current `for_each` entry, or `{<lock path>}` for another value. `{{`
and `}}` are literal braces.

Every rule accepts `name` (its group label) and `formats` (lock path to a
format such as `hex40`, `hex64`, `sri`, `sha512`, `nonempty`,
`positive-int` or `https-url`). Rules that iterate also accept `for_each`
(a lock path of an object; the rule runs once per entry) and `only_with`
(skip entries without that field).

## Rule kinds

Core rules are always on; component rules come from
`pins.rules` of the enabled components, in manifest order.

| Kind | Declared by | Fields | Check | Sync |
| --- | --- | --- | --- | --- |
| `flake-inputs` | core | `excluded` (from `[pins] excluded_flake_inputs`) | `flake_inputs` equals the root inputs of `flake.lock`; each reference, revision and NAR hash agrees with its node and `flake.nix` | references, revisions and hashes from `flake.lock` |
| `nix-package-format` | core | none | every `nix_packages` entry is well formed: `resolved` equals `expected` (unless `expected` is `"locked nixpkgs package"`), tags and revisions have the right shape | `official_tag` |
| `derive` | components | `to`; `from` or `template`; `for_each`, `only_with` | the value at `to` equals its source | writes `to` |
| `download-pin` | core (Nix installer), components | `at`, `version_field`, `url_field`, `size_field`, `sha256_field`, `url_contains`; `for_each`, `only_with` | a pinned download has a version, an HTTPS URL that contains the version, a positive size and a hex SHA-256 | none |
| `text-guard` | components | `file`, `template`; `for_each`, `only_with` | an instance file contains a text built from lock values | none |
| `no-literal` | core, components | `files`, `patterns` (`sri`, `fake-hash`), `regexes`, `values` | the files contain no literal pin or placeholder hash | none |
| `npm-bundle` | components | `dir`, `dependencies_at`, `overrides_at`, `mirrors`, `security_overrides_at`, `nix_hash_at` | an npm package directory, its lockfile and the lock values that mirror them agree | the mirrored values |
| `skills-lock-mirror` | components | `pairs` of `from` and `to`; `for_each`, `only_with` | values the skills lock repeats equal their source | writes the copies |
| `minimum-version` | components | `minimums_at`, `actual_from` | versions stay at or above declared minimums | none |
| `asset-digest` | components | `path_at`, `sha256_at` | a file of the instance has its pinned SHA-256 | none |
| `nix-resolved` | core, with `--nix` | `attr` (default `lib.pinnedVersions`) | `nix_packages.<name>.resolved` equals the version Nix evaluates | writes `resolved` |
| `skill-digests` | core | `sentinels` | every skills lock digest is well formed; repo-owned skills match their files; no entry is a framework skill | the digests of repo-owned skills and of `--skill` names |

The core `no-literal` rules forbid SRI and placeholder hashes in the
instance's `flake.nix`, `home.nix` and `components/**/*.nix`, and
placeholder hashes in both lock files. The module of each kind,
`engines/pins/dotsteward_pins/rules/<kind>.py`, documents its fields and
messages in full.

## Latest adapters

`dotsteward pins latest` builds one report row per pin. Rows come from the
`pins.latest` declarations of the enabled components and from built-in
rows derived from the lock files; a declared row replaces a built-in row
with the same id. Base URLs, repositories and asset names live only in
declarations.

| Adapter | Source |
| --- | --- |
| `github-release` | the newest stable GitHub release, with per-platform asset size and digest; `gh`, then `git ls-remote --tags` |
| `npm` | the `latest` dist-tag of an npm package, with integrity and engines |
| `apt-index` | the highest version in a vendor's APT `Packages` index |
| `deb-url` | a vendor link that always serves the newest DEB (redirect target, size, date) |
| `official-manifest` | a vendor's JSON release manifest: version, SHA-256 and size fields |
| `nix-release` | the newest stable Nix release and its published installer checksum |
| `channel-head` | the head of a release channel branch (nixpkgs, Home Manager); a newer series is `review` |
| `git-compare` | changes of watched paths in a repository since the pinned commit |
| `skill-source` | changes of a vendored skill upstream (`release_bound`: since the newest release tag) |
| `local-apt` | the candidate of this machine's APT configuration (with `--all`) |
| `manual` | no automatic source; the row reminds you to look |
| `follows` | a version derived from another pin (with `--all`) |
| `framework` | the newest release of the dotsteward upstream (built in) |

Each row has a status:

| Status | Meaning |
| --- | --- |
| `update` | a newer version in the same major series |
| `review` | a newer major version, a moved channel series, changed watched paths or a newer framework release |
| `held` | newer, but the pin declares a `holdback_reason` |
| `manual` | no automatic source |
| `error` | the source could not be read or changed format; never a silent pass |
| `current` | up to date |
| `follows` | derived from another pin |

The report (`--out`) is `{"schema_version": "1.0", "researched_at": ...,
"items": [...]}`. One failing source never stops the others: its rows
become `error` rows. How a refresh uses the report is described in
[update-policy.md](update-policy.md).
