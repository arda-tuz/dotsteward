# Sources, hashes and exact checks

## Contents

1. What `pins latest` queries
2. Hash and lockfile commands
3. Exact checks
4. Outage, disk and memory rules
5. What the gate covers

## What `pins latest` queries

Every row comes from a declaration: the built-in rows from the lock files, the other rows from the component that owns the pin (catalog components in the framework source, private components in the instance's `components/`). Base URLs, repositories and asset names live only in those declarations.

| Adapter | Typical rows | Official source |
| --- | --- | --- |
| `channel-head` | nixpkgs, Home Manager (`flake_inputs.<name>` with a `channel`) | `git ls-remote` of the channel branches (`nixos-YY.MM`, `release-YY.MM`); a newer series is reported as `review` |
| `github-release` | flake inputs with a `version`, release archives, Nix package sources | GitHub releases (tags when a repository has no releases), per-platform asset size and `digest` |
| `npm` | npm dependencies and npm-distributed tools | registry `latest` dist-tag, integrity, `gitHead`, engines |
| `apt-index` | desktop packages from a vendor APT repository | the vendor's `dists/<dist>/<component>/binary-<arch>/Packages` index |
| `deb-url` | vendor packages without an index | the vendor's newest-package link (redirect target, size, date) |
| `official-manifest` | applications with a JSON update manifest, such as VS Code or Claude Code | the vendor manifest's version, SHA-256 and size fields |
| `nix-release` | the Nix installer (`nix.installer`) | stable tags of the Nix repository and the published installer checksum |
| `git-compare` | upstream paths another pin depends on | GitHub compare from the recorded revision, watched paths only |
| `skill-source` | vendored skills (`skills.<name>`) | GitHub compare filtered to the vendored files and the skill structure; `release_bound` skills compare against the latest release tag |
| `local-apt` | local APT floors (with `--all`) | `apt-cache policy` on this machine |
| `manual` | pins without an automatic source | the source named in the row |
| `follows` | versions derived from another pin (with `--all`) | none; refresh with `./.dotsteward/cli.sh sync --nix` after the pin they follow moves |
| `framework` | the dotsteward framework (`framework`) | the newest stable release of the framework upstream from `flake.lock`; `review` when newer (`framework-upgrade.md`) |

A `holdback_reason` on a lock entry turns a newer upstream version into a `held` row that shows the reason. Upstream format changes produce an `error` row, never a silent pass.

## Hash and lockfile commands

Every command reproduces the current pins exactly; run them from the clone root after staging with `git add -A`. Use the current system from the context, never a literal one:

```bash
system=$(jq -r .platform.system "$work/context.json")
```

| Value | How |
| --- | --- |
| Flake input lock | `nix flake update <input>` after editing the URL in `flake.nix` |
| `fetchFromGitHub` hash of a source | `nix flake prefetch --json github:<owner>/<repo>/<tag>`, field `hash` |
| `fetchurl` hash (SRI) | `nix store prefetch-file --json <url>`, field `hash` |
| Hex SHA-256 of an archive | from the official digest of the research report, else the SRI hash converted with `nix hash convert --hash-algo sha256 --to base16 <sri>` |
| npm bundle hash (`npm-bundle` rule, `nix_hash_at`) | `prefetch-npm-deps` over the bundle's `package-lock.json`, below |
| npm dependency hash of a package source | build the package's `src`, then `prefetch-npm-deps` over its `package-lock.json`, below |
| Vendored dependency hashes (Cargo, Go modules) | set each changed value to the placeholder below, run one build of every changed dependency derivation and copy each `got:` value; `pins check` rejects the placeholder, so it cannot slip through |
| npm lockfile | regenerate it with the Nix-provided Node.js and audit it, below; the audit must report 0 vulnerabilities |

```bash
nix flake prefetch --json "github:$owner/$name/$tag" >"$work/prefetch.json"
jq -r .hash "$work/prefetch.json"
nix store prefetch-file --json "$url" >"$work/prefetch.json"
jq -r .hash "$work/prefetch.json"
nix hash convert --hash-algo sha256 --to base16 "$sri"
nix shell --inputs-from . nixpkgs#prefetch-npm-deps -c prefetch-npm-deps "$bundle/package-lock.json"
src=$(nix build --no-link --print-out-paths ".#packages.$system.$package.src")
nix shell --inputs-from . nixpkgs#prefetch-npm-deps -c prefetch-npm-deps "$src/package-lock.json"
nix build --no-link --keep-going ".#packages.$system.$package.cargoDeps" ".#packages.$system.$other.goModules"
nix shell --inputs-from . nixpkgs#nodejs -c npm --prefix "$bundle" install --package-lock-only --ignore-scripts --no-audit --no-fund
nix shell --inputs-from . nixpkgs#nodejs -c npm --prefix "$bundle" audit
```

The placeholder for a vendored dependency hash is `sha256-` followed by 43 `A` characters and `=`. Use the Node.js package the component's `maintenance.md` names (for example a versioned `nodejs_<major>` attribute) instead of `nodejs` when it names one, so the lockfile does not depend on the user's own Node.js installation.

## Exact checks

Some pins carry requirements that another tool dictates (exact linter versions, minimum versions of a workflow tool) or acceptance checks that need special conditions. The component's `maintenance.md` or the overlay names them. Run only those exact checks, and only for rows the report marks `review`. Never substitute a full third-party lint or test suite: it is not part of the instance contract and can take very long.

## Outage, disk and memory rules

- Binary cache (`gate.cache_url`) unreachable: stop and report; retry later. No mirrors or extra substituters.
- Disk: the prepare step warns below `prepare_warn_free_gib` GiB free on `/nix/store` (the `[gate]` table of `workstation.toml`); the gate stops below `gate.min_free_gib` of the context. Ask the user before freeing space. Never run `nix-collect-garbage` or delete Home Manager generations on your own: it removes rollback points and forces cold rebuilds.
- Memory: the gate builds with `gate.nix_max_jobs` jobs and `gate.nix_cores` cores (`DOTSTEWARD_NIX_MAX_JOBS` and `DOTSTEWARD_NIX_CORES` override them for one run). Do not raise them unless the user agrees; a build that runs out of memory costs more than a slow one. The overlay may state the limits of this machine.

## What the gate covers

The gate proves that the tree builds, the pins agree, the static contracts hold (the launcher and `bootstrap.sh` equal the pinned framework's `template/`), the privacy scan is clean and the CLIs of the check profile report the locked versions and required features. It does not test physical devices, GUI applications or account-bound flows; report those as not exercised unless the user asked for local activation.
