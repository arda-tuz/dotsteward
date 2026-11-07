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
Nix installer read by the first bootstrap), `flake_inputs`,
`nix_packages` and `trust` ([Authenticity](#authenticity)). Every other section belongs to the components that declare
rules for it.

## Commands

```sh
dotsteward pins check            # every rule, offline
dotsteward pins check --nix      # also the versions Nix resolves
dotsteward pins sync             # rewrite derived values
dotsteward pins sync --skill NAME
dotsteward pins latest --out report.json
dotsteward pins apply            # move the pins to the rows of latest
dotsteward generate                  # pins sync plus the .dotsteward/ mirrors
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
| `text-guard` | components | `file`, `template`; `regenerate`, `for_each`, `only_with` | an instance file contains a text built from lock values | none |
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
| `pypi` | the newest final release of a package on a Python package index (pre-releases and yanked releases skipped), with its `requires_python` |
| `apt-index` | the highest version in a vendor's APT `Packages` index |
| `deb-url` | a vendor link that always serves the newest DEB (redirect target, size, date) |
| `official-manifest` | a vendor's JSON release manifest: version, SHA-256 and size fields |
| `nix-release` | the newest stable Nix release and its published installer checksum |
| `channel-head` | the head of a release channel branch (nixpkgs, Home Manager); a newer series is `review` |
| `git-compare` | changes of watched paths in a repository since the pinned commit |
| `skill-source` | changes of a vendored skill upstream (`release_bound`: since the newest release tag); when GitHub truncates the compare's file list (300 files), the tree of the skill's `source_path` at both commits decides |
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

## The writer

`dotsteward pins apply` moves the pins to the rows of `pins latest`, without an
agent's judgment, and leaves the result in the working tree: it never commits or
publishes. It researches itself, or takes a saved report with `--latest FILE`;
`--plan` shows what would happen and writes nothing at all; `--skip ID` (a glob,
repeatable) leaves rows alone; `--json` prints the summary (`moved`, `groups`,
`lines`, `items`, `framework_moved`, `flake_inputs_moved`, `report`).

| Row | What happens |
| --- | --- |
| `update` | moves |
| `review` | moves when it is an unconstrained new major or a framework minor or patch, a review item otherwise |
| `held`, `manual` | a line of the report |
| `error` | a line of the report; the group it belongs to waits, the others go on |

The writer finds out how a pin moves from what the instance already declares, and
a row nothing explains is a review item (`pins-no-writer`):

| Pin | Group | What is written |
| --- | --- | --- |
| the framework | `framework` | the reference in `flake.nix`, `flake.lock`, `bootstrap.sh` and `.dotsteward/cli.sh` from the new `template/`, the mirrors |
| a flake input | `channel` (all channel inputs together), `flake:<name>` | the reference, `flake.lock` with `nix flake lock`, the lock fields, the pins that derive from it |
| a `*_nix_sha256` field | `nix-package:<name>` | the version, the tag fields, each hash from a build with the placeholder hash |
| a `download-pin` rule | `download:<id>` | the fields the rule names, from the row or from one prefetch |
| a `text-guard` with `regenerate` over a `pypi` pin | `pypi:<file>` | the hash-pinned requirements, from the command the rule declares |
| an `npm-bundle` rule | `npm:<dir>` | `package.json`, `package-lock.json` with an audit, the mirrors, the bundle hash |
| a vendored skill | `skill:<name>` | the whole directory, the revision and the digests |

`regenerate` is what the component declares, because the framework names no compiler of
requirements: `{ "package": "<nixpkgs attribute>", "command": ["<argv>"] }`. The command runs with
that package of the nixpkgs the instance locks on its PATH, reads the `.in` file next to the
guarded file (else `<package>==<version>` of the moves) on standard input and prints the new file. A
guarded file without `regenerate` has no writer: its row waits as `pins-no-writer`.

A group moves as a whole: on a failure every byte it touched is restored, the step
is `failed` and the other groups go on. A second run with the same rows does nothing,
because a pin that already holds the value of its row does not move.

These stay for a person or an agent, as items of `review.json`: a pin with a
`*_reason` field, a version another rule derives, a `version` in the component's
configuration or a new major of a security override (`pins-constrained`); a newer
series of a channel (`series-available`); a framework major (`framework-major`); a
changed watched path (`pins-review`), since moving it is an inspection; a release
without the asset (`asset-missing`); a bundle whose audit findings grow, or whose audit
gives no answer (`npm-audit`; findings that do not grow move the bundle and stand in the
report as `npm-audit-remaining`, which waits for nothing);
and for a skill a vendored copy that is not upstream at the pinned revision
(`skill-local-delta`), a finding of `dotsteward scan` in the new version
(`skill-scan-finding`) or an upstream without the directory (`skill-source-missing`).
A skill with a recorded `source_transform` is `skill-transform`: the transform is prose only
an agent can replay, so it is work for `dotsteward-update`, and it stands in the report without
holding the exit status. Repo-owned skills have no row and are never touched. A plugin marketplace
(`observed_marketplace_revision`) updates itself: a line of the report.

Exit codes are those of a run report ([exit-codes.md](exit-codes.md)): 0 done, 1 a
group failed, 3 review items wait, 6 an upstream could not be read. The run report is
`pins-apply`.

## Authenticity

The digest of a pin binds the file the pin names; a digest published next to the
file catches corruption, not a compromised release. So when the writer moves a
`download-pin` it also looks for a signature of the new file and verifies it:

1. A Sigstore bundle published next to the file: `<url>.sigstore.json`,
   `<url>.sigstore`, `<url>.bundle`, and for an archive (`.tar.gz`, `.tgz`,
   `.tar.xz`, `.txz`, `.tar.bz2`, `.tbz2`, `.tar`, `.zip`) the same names after the
   archive without its extension: the signature of the member of that name (the
   layout of release workflows that sign the binary inside the archive).
2. Otherwise, when the declaration names a GitHub repository, a GitHub artifact
   attestation of the digest (`gh api repos/<repo>/attestations/sha256:<digest>`,
   then `gh attestation download`): build provenance
   (`https://slsa.dev/provenance/v1`) logged in the public transparency log.

Every lookup has a timeout (60 seconds each, 180 for one pin), and a lookup that
fails counts as nothing found, so discovery never holds a run. The trusted root
comes from `gh attestation trusted-root` (the GitHub CLI checks it with TUF), else
the one the lock recorded. cosign verifies the bundle against it with the
signer's identity regular expression and OIDC issuer; it needs no network.

The first verified signer of a pin is trusted on first use: the lock records its
certificate identity as a regular expression, escaped, with every run of digits after
`@refs/tags/` generalized (so the next release of the same workflow matches and no
other workflow, repository or branch does), and its OIDC issuer. The report says
`trusted on first use`. From then on:

| Found | Result |
| --- | --- |
| a signature of the pinned signer that verifies | the pin moves with the signature |
| a signature of another identity or issuer | `authenticity-signer-changed`; the pin stays |
| a signature that does not verify | `authenticity-failed`; the pin stays |
| no signature for a signed source | `authenticity-signature-missing`; the pin stays |
| a signature, and no trusted root | `authenticity-no-trusted-root`; the pin stays |
| no signature for an unsigned source | the pin moves, labelled `unsigned` |

A source that never offered a signature moves as before: there is no minimum
release age for unsigned files (decision T8-a). Its signer entry says
`unsigned` and the report labels the move: the `pins apply` line
(`moved <id>: <from> -> <to> (unsigned)` or `(sigstore: <identity>)`), the
`authenticity` of each entry of `moved` in the JSON summary and the step of the
run report. Requirements of a `pypi` group and packages built from source are
labelled `unsigned` too; their PEP 740 attestations and upstream signatures are
not read yet.

What the lock holds:

```json
"agent_tools": { "example": { "minimum_version": "1.2.0", "url": "https://...", "size": 1, "sha256": "...",
  "signature": { "kind": "message", "subject": "member", "member": "example-linux",
                 "identity": "https://github.com/example/example/.github/workflows/release.yml@refs/tags/v1.2.0",
                 "bundle": { "mediaType": "application/vnd.dev.sigstore.bundle+json;version=0.1", "...": "..." } } } },
"trust": {
  "sigstore_root": { "mediaType": "application/vnd.dev.sigstore.trustedroot+json;version=0.1", "...": "..." },
  "signers": {
    "agent_tools.example": { "kind": "sigstore",
      "identity_regexp": "^https://github\\.com/example/example/\\.github/workflows/release\\.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$",
      "issuer": "https://token.actions.githubusercontent.com", "first_seen": "2026-11-01" },
    "agent_tools.other": { "kind": "unsigned", "first_seen": "2026-11-01" } } }
```

`kind` is `message` (a signature of the file) or `attestation` (an in-toto statement
in DSSE, with its `predicate_type`); `subject` is `asset` (the downloaded file) or
`member` (a file of the archive). The bundle is the one cosign verified; a legacy
cosign bundle (`base64Signature`, `cert`, `rekorBundle`) is converted to a v0.1
Sigstore bundle first, since cosign reads a trusted root only with Sigstore
bundles. The install methods verify a recorded signature again after the
download and before anything is replaced (`official-binary`, `deb`,
`app-archive`), from the lock alone; `verify = "sha256+sigstore"` makes the
signature of an `official-binary` pin mandatory
([component-contract.md](component-contract.md)). Attestations GitHub issues for
private repositories (its own certificate authority and timestamps, no
transparency log entry) are not read.
