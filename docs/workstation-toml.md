# workstation.toml

`workstation.toml` at the root of an instance is its configuration: who the
checks run as, which systems and profiles exist, which components are
enabled, and how the gate, the pins engine, the settings buffer, the skills
and the contribution flow behave. Every key except a few required ones has a
default, so a new instance written by `dotsteward init` is short (see
[the example](#example)).

The file is validated against `schema/workstation.schema.json` (schema
version 1) by the Nix library and by the CLI, with the same rules: an unknown
key, a wrong type or a value outside its allowed set is an error that names
the key. Paths described as instance paths are relative to the instance root
and may not leave it.

## Top level

| Key | Default | Meaning |
| --- | --- | --- |
| `schema_version` | required | Always `1`. Another value is an error with an upgrade hint. |
| `protected` | `{}` | Byte-protected files: instance path to the sha256 hex digest of its content. `dotsteward static` fails when a file no longer has its digest. |

## `[identity]`

The check identity: the user that sandbox builds, `homeConfigurations.<username>`
and the gate evaluate for. Activation always uses the user who runs it
(`$USER` and `$HOME`), so an instance installs on a machine with another
user name or home without any edit.

| Key | Default | Meaning |
| --- | --- | --- |
| `identity.username` | required | The check user name. With a Linux system it must match `^[a-z_][a-z0-9_-]*$`. |
| `identity.home` | `/home/<username>` | The check home on Linux. |
| `identity.darwin_home` | `/Users/<username>` | The check home on `aarch64-darwin`. |

## `[instance]`

| Key | Default | Meaning |
| --- | --- | --- |
| `instance.remote` | required | Exactly what `git remote get-url origin` prints in a clone. The gate, `update publish` and the end-to-end checks compare it byte for byte. |
| `instance.name` | the directory name | Display name. |
| `instance.branch` | `"main"` | The published branch. |
| `instance.checkout` | `~/<instance.name>` | The canonical clone on every machine. |

## `[state]`

| Key | Default | Meaning |
| --- | --- | --- |
| `state.root` | `${XDG_STATE_HOME:-~/.local/state}/dotsteward` | Root of every machine record: backups, transaction records, logs, the launcher cache. `DOTSTEWARD_STATE_ROOT` overrides it. |

## `[nix]`

| Key | Default | Meaning |
| --- | --- | --- |
| `nix.systems` | `["x86_64-linux"]` | Systems to build, from `x86_64-linux` and `aarch64-darwin`. The first one is the primary system. |
| `nix.allow_unfree` | `false` | nixpkgs `config.allowUnfree`. |
| `nix.state_version` | required | Home Manager's `home.stateVersion`. |

## `[profiles]`

A profile is a named way to apply the instance (see
[concepts.md](concepts.md#profiles)). Each name of `profiles.names` may have
a `[profiles.<name>]` table.

| Key | Default | Meaning |
| --- | --- | --- |
| `profiles.names` | required | The allowed profile names. |
| `profiles.default` | the first name | The profile of `mkHome` when none is given. |
| `profiles.check` | `profiles.default` | The profile of `homeConfigurations`, `checks.<system>.home` and the gate's CLI probes. |
| `profiles.bootstrap` | `profiles.default` | The only profile `bootstrap.sh` accepts. |
| `profiles.<name>.mode` | `"fresh"` | `fresh` installs system-level parts (system packages, `deb` and `app-archive` components, system hooks); `adopt` skips them and reports such components as `not-managed`. |

## `[platform]`

The fast path of each platform: a machine that matches it is supported
without questions, any other machine takes the adaptive route (preflight
exit 3). See [platforms.md](platforms.md).

| Key | Default | Meaning |
| --- | --- | --- |
| `platform.linux.fast_path.os_id` | `"ubuntu"` | `ID` of os-release. |
| `platform.linux.fast_path.os_version` | `"24.04"` | `VERSION_ID` of os-release. |
| `platform.linux.fast_path.architecture` | `"x86_64"` | `uname -m`. |
| `platform.linux.fast_path.desktop_contains` | none | A case-insensitive substring of `XDG_CURRENT_DESKTOP`. |
| `platform.linux.fast_path.detectors` | `[]` | Names of component preflight detectors, ORed with `desktop_contains`. |
| `platform.darwin.fast_path.min_version` | `"14"` | The lowest macOS version. |
| `platform.darwin.fast_path.architecture` | `"arm64"` | `uname -m`. |

## `[gate]`

The parameters of the validation gate (`dotsteward gate`).

| Key | Default | Meaning |
| --- | --- | --- |
| `gate.nix_max_jobs` | derived from the machine | `--max-jobs` of the gate's Nix builds (`DOTSTEWARD_NIX_MAX_JOBS`). |
| `gate.nix_cores` | derived from the machine | `--cores` of the gate's Nix builds (`DOTSTEWARD_NIX_CORES`). |
| `gate.min_free_gib` | `5` | Free GiB the gate requires in `/nix/store` (`DOTSTEWARD_MIN_FREE_GB`). |
| `gate.prepare_warn_free_gib` | `15` | Below this many free GiB, `update prepare` warns. |
| `gate.cache_url` | `"https://cache.nixos.org"` | The binary cache the gate requires to answer (`DOTSTEWARD_CACHE_URL`). |
| `gate.static` | `[]` | Instance static scripts, run by the gate's static step and by `checks.instance-static`. |
| `gate.update_allowlist` | `[]` | Extended regular expressions added to the paths an update-scope transaction may change. |

When `gate.nix_max_jobs` or `gate.nix_cores` is not set, the CLI derives it
from the machine on every run, so that a small machine does not run out of
memory while building:

- the budget is the total memory minus 2048 MiB for the evaluation and the
  system;
- `nix_max_jobs` is one job per full 6144 MiB of the budget, at most one per
  CPU and at least one;
- `nix_cores` is the CPUs divided among the jobs, at most one core per full
  1024 MiB of a job's share of the budget, and at least one.

A 4 GiB machine therefore builds one derivation at a time on one core, an
8 GiB machine with 8 CPUs one derivation on 5 cores, and a 16 GiB machine
with 12 CPUs two derivations on 6 cores each. A value set in
`workstation.toml` (for example `nix_max_jobs = 2` and `nix_cores = 6`)
applies on every machine instead, and `DOTSTEWARD_NIX_MAX_JOBS` and
`DOTSTEWARD_NIX_CORES` override both for one run. `DOTSTEWARD_MEMORY_MIB`
and `DOTSTEWARD_CPU_COUNT` replace the memory (in MiB) and the CPU count the
derivation reads, for example in a container whose limits are lower than
the host's. `dotsteward context --json` shows the values in effect.

## `[commit]`

| Key | Default | Meaning |
| --- | --- | --- |
| `commit.update_subject` | `"chore: update pinned tool versions"` | The subject `update publish` requires on the last commit of an update-scope transaction. |
| `commit.settings_subject` | `"chore: sync local maintained settings"` | The subject of a settings write-back commit. |
| `commit.upgrade_subject` | `"chore(dotsteward): upgrade to {version}"` | The subject of a framework upgrade commit; `{version}` is the release without its `v`. |

## `[components]`

| Key | Default | Meaning |
| --- | --- | --- |
| `components.order` | catalog order | Hook and check order. Listed components come first, then the remaining catalog components in catalog order, then the instance components sorted by name. |

Each component has its own `[components.<name>]` table. `<name>` is a
catalog component (see [catalog.md](catalog.md)) or a private component in
`components/<name>/default.nix` of the instance.

| Key | Default | Meaning |
| --- | --- | --- |
| `components.<name>.enable` | `false` | Whether the component is part of the instance. |
| `components.<name>.source` | `catalog` for a catalog name, else `instance` | Where the module comes from. |
| `components.<name>.method` | the component's default | The install method on every platform: `nix`, `official-binary`, `deb`, `app-archive` or `external`. |
| `components.<name>.method_by_platform.linux` | none | The method on Linux; wins over `method`. |
| `components.<name>.method_by_platform.darwin` | none | The method on macOS; wins over `method`. |
| `components.<name>.profiles` | every profile | The profiles where the component is active. |
| `components.<name>.options` | `{}` | Options owned by the component, passed to its module unchanged; its README documents them. |

## `[settings]`

The settings buffer (see [concepts.md](concepts.md#settings-buffer)).

| Key | Default | Meaning |
| --- | --- | --- |
| `settings.buffer_dir` | `"local-maintained-files"` | The instance directory of the buffer. |
| `settings.published_ref` | `origin/<instance.branch>` | The reference whose buffer counts as published. |

## `[skills]`

| Key | Default | Meaning |
| --- | --- | --- |
| `skills.lock` | `"agent/skills.lock.json"` | The lock of the vendored instance skills. |
| `skills.vendor_dir` | `"agent/skills"` | The directory of the vendored instance skills. |
| `skills.hm_root` | `".agents/skills"` | Home-relative root where Home Manager deploys skills. |
| `skills.installer` | the native copy | An installer argv template with `{source}`, `{name}` and `{home}`. |
| `skills.overlays` | `{}` | An overlay file per framework skill; `agent/overlays/<skill>.md` is used when it exists and no entry is given. |

## `[pins]`

| Key | Default | Meaning |
| --- | --- | --- |
| `pins.versions_lock` | `"versions.lock.json"` | The lock of every pinned version, URL and hash. |
| `pins.excluded_flake_inputs` | `["dotsteward"]` | Flake inputs the pins engine does not compare with the lock. |
| `pins.nixpkgs_versions` | `{}` | A `nix_packages` key of the lock to the nixpkgs attribute path whose version it pins. |
| `pins.apt_arch` | `"amd64"` | The APT architecture of `deb` pins. |

## `[privacy]`

The instance's own privacy policy, applied by `dotsteward static` and the gate.

| Key | Default | Meaning |
| --- | --- | --- |
| `privacy.forbidden_paths` | `[]` | Globs of paths the instance never tracks (`*` also matches `/`). |
| `privacy.file_rules` | `[]` | Rules with `files` (globs), `pattern` (an extended regular expression) and `message`: a matching line in a matching file is a finding. |
| `privacy.denylist` | none | An optional denylist file of private terms, read outside the Nix sandbox. |

## `[agent_rules]`

| Key | Default | Meaning |
| --- | --- | --- |
| `agent_rules.source` | `"home/AGENTS.md"` | The shared rules file linked into each agent's configuration. |

## `[upstream]`

The framework contribution flow (`dotsteward contribute`).

| Key | Default | Meaning |
| --- | --- | --- |
| `upstream.contribute` | `"fork"` | `fork`: changes land in your fork; `owner`: direct merge and release, which also needs push permission on the upstream repository. |
| `upstream.fork` | `<gh user>/dotsteward` | The fork as `owner/repo`. |
| `upstream.pr_to_upstream` | `false` | In fork mode, also open an upstream pull request. |
| `upstream.local_clone` | `${XDG_DATA_HOME:-~/.local/share}/dotsteward/framework` | The local clone of the framework. |

## `[compat]`

Switches for an instance migrated from an older setup. A new instance
leaves them at their defaults.

| Key | Default | Meaning |
| --- | --- | --- |
| `compat.legacy_env` | `false` | Also read the legacy `DOTFILES_*` environment names. |
| `compat.legacy_backup_layout` | `false` | Also find backups in the legacy `files/home/<path>` layout. |
| `compat.repo_owned_revision` | none | A legacy sentinel the pins engine accepts as a revision. |
| `compat.host_input` | `"instance"` | The input name of the instance in the host flake that `rebuild` writes. |
| `compat.check_aliases` | `{}` | Extra `checks.<system>.<name>` aliases of `home-<profile>`. |

## Example

Run as the user `example` (home `/home/example`),
`dotsteward init --dir ~/workstation --remote git@github.com:example/workstation.git --components shell,claude-code`
writes:

```toml
# The instance configuration (schema 1), written by `dotsteward init`. The
# framework documents every key in docs/workstation-toml.md and
# schema/workstation.schema.json of its repository.
schema_version = 1

# The check identity: sandbox builds, homeConfigurations.<username> and the
# gate. Activation always uses the user who runs it ($USER and $HOME).
[identity]
username = "example"

[instance]
name = "workstation"
# Exactly what `git remote get-url origin` prints in your clone.
remote = "git@github.com:example/workstation.git"
# Where the canonical clone lives on every machine.
checkout = "~/workstation"

[nix]
# The first system is the primary one; add "aarch64-darwin" for a Mac.
systems = ["x86_64-linux"]
allow_unfree = false
state_version = "26.05"

# Profiles: adopt manages your files on a machine that is already set up;
# fresh also installs system packages on a new machine (bootstrap.sh).
[profiles]
names = ["workstation", "fresh"]
default = "workstation"
check = "workstation"
bootstrap = "fresh"

[profiles.workstation]
mode = "adopt"

[profiles.fresh]
mode = "fresh"

# Components: one [components.<name>] table each, with enable = true, for the
# catalog (shell, herdr, claude-code, codex, opencode-pi, vscode) and for
# your own components in components/<name>/.
[components]
order = ["shell", "claude-code"]

[components.shell]
enable = true

[components.claude-code]
enable = true

[upstream]
contribute = "fork"
```
