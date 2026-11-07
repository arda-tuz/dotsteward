# codex

The Codex CLI (`codex`), its agent rules link, its configuration file as a
settings target, its legacy skill root and, optionally, Codex plugins.

Enable it in `workstation.toml`:

```toml
[components.codex]
enable = true
# method = "external"                       # default: "official-binary"
# method_by_platform = { darwin = "external" }
```

## What it installs

| Platform | Default method | What lands on the machine |
| --- | --- | --- |
| Linux (x86_64) | `official-binary` | `codex-x86_64-unknown-linux-musl` from the release archive `codex-x86_64-unknown-linux-musl.tar.gz`, installed as `~/.local/bin/codex` (mode 0755); `codex-code-mode-host-x86_64-unknown-linux-musl` from `codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz`, installed as `~/.local/bin/codex-code-mode-host` (mode 0755) |
| darwin (aarch64) | `official-binary` | `codex-aarch64-apple-darwin` from the release archive `codex-aarch64-apple-darwin.tar.gz`, installed as `~/.local/bin/codex` (mode 0755); `codex-code-mode-host-aarch64-apple-darwin` from `codex-code-mode-host-aarch64-apple-darwin.tar.gz`, installed as `~/.local/bin/codex-code-mode-host` (mode 0755) |

All archives come from the official GitHub releases of `openai/codex`
(tags `rust-v<version>`). The pins live in `versions.lock.json` under
`agent_tools.codex.<platform>` and
`agent_tools.codex-code-mode-host.<platform>`, each with `version`, `url`,
`size` and `sha256`; `dotsteward init` writes them from `seed.json`. Only
the platforms of `nix.systems` whose method is `official-binary` declare
pins.

The installer runs at user level (no root) during `dotsteward rebuild
--switch` and `dotsteward agents install`:

1. download the pinned archives over HTTPS (TLS 1.2 or newer);
2. compare the size, then the SHA-256 of each with its pin, and refuse on any
   difference before anything is replaced;
3. extract the single member of each and install it at its destination;
4. read the version from `codex --version` (`codex-cli <version>`) and see
   the helper in place.

The policy is `at-least`: a binary that reports the pinned version or a
newer one is kept (Codex may update itself), an older one is replaced, and
the pin is never downgraded. A symlink at `~/.local/bin/codex` or
`~/.local/bin/codex-code-mode-host` is refused.
`dotsteward install --check-only` and `dotsteward agents check` report a
missing or older binary, or a missing helper, with the rebuild hint and
change nothing.

## The helper

From 0.144.0 on, Codex runs Code Mode, and with it `apply_patch`, through a
second executable, `codex-code-mode-host`. It starts the file from the
directory of its own resolved executable. A session without the file says
`failed to spawn code-mode host <dir>/codex-code-mode-host` and the model
cannot edit files.

- **A binary that meets the pin stays and gets what it lacks.** A missing
  helper is fetched alone, from `agent_tools.codex-code-mode-host.<platform>`.
- **A file already in place is kept**, without a download and with or without
  a pin. The helper has no `--version`, so the method cannot tell its release;
  it is replaced with the next pin bump.
- **A pin bump moves both files**, staged and verified before either is
  replaced. The two pins hold one version: `dotsteward pins check` compares
  them and the install refuses a pair that differs.
- **Older pins keep working.** A codex older than 0.144.0 is asked for nothing
  (0.143.0 ships the helper with the feature off, earlier releases do not ship
  it), so a lock without the helper pin stays valid for those versions. At
  0.144.0 or newer such a lock is red only when the file is missing too:
  add the pin, or move to a release with `dotsteward pins latest`.
- **A link from the standalone installer is left alone.** Its helper is next
  to the link's target, where Codex looks, and the method never writes there.
- **A codex at another path** (found first on `PATH`, not at the destination)
  is not this method's and is asked for nothing.

The E2E hook `codex-code-mode-host` (with `official-binary`; not parallel, since
every `codex` start replaces its links under `$CODEX_HOME/tmp/arg0-linux`)
repeats that check and starts the helper with `--help`; it needs neither a
network nor an account. It also warns, without failing, about two things
the bare binary looks for on the system because it is not in a package:
`bwrap` on Linux (without it, sandboxed commands fail with `bubblewrap is
unavailable`) and `rg`.

The standalone package (`codex-package-<target>.tar.gz`) holds all of these and
more (`bin/codex`, `bin/codex-code-mode-host`, `bin/codex-exec-server`,
`codex-path/rg`, `codex-resources/bwrap`, `codex-resources/voice/`). This
component stays with the bare archives: the destination stays a regular file,
so the symlink rule of the method holds, and Codex reports its install method
as `other`, so nothing but the pin moves it. Inside
`~/.codex/packages/standalone` Codex reports `standalone` and offers its own
installer as the update action. The price is the system `bwrap` and `rg` above.

## Methods

| Method | Platforms | Behaviour |
| --- | --- | --- |
| `official-binary` | linux, darwin | the verified release archive above (default) |
| `external` | linux, darwin | nothing is installed; `codex` must be on `PATH` (installed by any other means), and the checks fail when it is not |

`external` declares no pins.

## The codex a login shell runs

With the `shell` component, the E2E hook `codex-login-path` (for the
profiles of the shell component, parallel: it only reads) asks an
interactive login zsh, the shell a terminal opens, for every `codex` on its
`PATH`. The expected one is `options.expectedPath`, else, with
`official-binary`, its destination `~/.local/bin/codex`:

```toml
[components.codex]
enable = true
method = "external"
options = { expectedPath = "~/.local/bin/codex" }
```

| Option | Type | Default | Effect |
| --- | --- | --- | --- |
| `expectedPath` | home path (`~/...`) or absolute path | none | the `codex` the first `PATH` entry must provide: the hook fails when it is not an executable file, when `codex` is not on `PATH`, or when another copy comes first (a link to the expected file counts as that file), and names that copy |

Without an expected location (`external` without `expectedPath`) the hook
only warns when more than one `codex` is on `PATH`, naming the one that
runs first.

## Agent rules, settings and backups

- Agent rules: `~/.codex/AGENTS.md` links the instance's shared agent rules
  (`[agent_rules] source`). An existing regular file is replaced (`force`),
  after it was backed up; rollback removes the link and restores the backup
  as a regular file with mode 0664.
- Settings target `codex`: `~/.codex/config.toml` (TOML), created with mode
  0600 when a local-maintained-files entry needs it, backed up before every
  write, no reload command.
- Backup paths: `~/.codex/AGENTS.md`, `~/.codex/config.toml`.
- Skill layout: `~/.codex/skills` is a legacy skill root (created as a
  directory when the component is enabled); its `.system` subtree belongs to
  Codex and is never touched.
- The `skill-hooks` hook (`skill-hooks.sh`, an agentsPost hook) puts the hooks
  of skill tracking into `${CODEX_HOME:-~/.codex}/hooks.json`, and takes them
  out when `[skills] tracking` is off; `config.toml` stays as it is. Codex runs
  no hook of that file before `/hooks` trusted it, once per machine, so `skills
  hooks check` reports what waits; see
  [skill tracking](../../../docs/skill-tracking.md).

## Plugins

`options.plugins` lists Codex plugins to install and verify, one
`[[components.codex.options.plugins]]` table per plugin:

```toml
[components.codex]
enable = true

[[components.codex.options.plugins]]
spec = "example-plugin@example-market"
marketplace = "example-org/example-marketplace"
minimumAt = "agent_tools.example-plugin.minimum_version"
requiredSkillDirectories = ["alpha", "beta"]
trackAt = "agent_tools.example-plugin"
watched = ["plugins/example-plugin/.+"]
```

The inline form `options = { plugins = [ { spec = "..." }, ... ] }` is
equivalent, but TOML 1.0 requires each inline table on a single line.

| Key | Required | Meaning |
| --- | --- | --- |
| `spec` | yes | `NAME@MARKETPLACE`, as `codex plugin add` takes it |
| `marketplace` | no | the GitHub repository `OWNER/REPO` of a Git marketplace that `codex plugin marketplace add` adds under the spec's marketplace name; entries naming the same marketplace name the same repository |
| `minimumAt` | no | a `versions.lock.json` path holding the minimum version: a version string, or an entry with `minimum_version` or `version` |
| `requiredSkillDirectories` | no | directory names that must hold `skills/<name>/SKILL.md` inside the installed plugin |
| `machines` | no | the names of the machines the plugin is for; other machines neither install it nor miss it ([machines](../../../docs/machines.md)) |
| `trackAt` | no | a `versions.lock.json` path of an entry with `source` (`https://github.com/OWNER/REPO` of the marketplace) and `observed_marketplace_revision` (the 40-digit commit the plugin was last reviewed at); needs `watched` |
| `watched` | with `trackAt` | regular expressions (full match) of the marketplace paths that belong to the plugin |

A non-empty list adds the `plugins` hook (`plugins.sh`, an agentsPost hook:
agents phase, before validation). `dotsteward agents install` first runs
`codex plugin marketplace add OWNER/REPO` for each `marketplace` that
`codex plugin marketplace list --json` does not list under the spec's
marketplace name, then `codex plugin add SPEC` for each plugin that
`codex plugin list --json` does not show installed and enabled. The hook
reads each of the two lists once for all entries, and again only after a
command that changed it. Both `agents install` and `agents check` then
verify every plugin:

- the marketplace an entry names is listed under the spec's marketplace
  name, as a Git marketplace from `https://github.com/OWNER/REPO` (a
  trailing `.git` and letter case aside);
- it is listed as installed and enabled, with a plain version string;
- its directory (the cached copy
  `${CODEX_HOME:-~/.codex}/plugins/cache/<marketplace>/<name>/<version>`
  when it holds a manifest, else the listed local source path) holds
  `.codex-plugin/plugin.json` with the same version. The listed version is
  that of the cached copy, which Codex loads; the local source of a plugin
  at the root of a Git marketplace is the marketplace snapshot, which a
  session that ends early leaves ahead of the cache, and that is no defect;
- the version is at least the lock minimum; an older plugin fails and is
  never upgraded silently;
- every required skill directory has a `SKILL.md`.

`agents check` never installs anything. It reads the plugin list again
for a plugin that the list does not show, up to four times, after a pause
of 2, 4, 8 and 16 seconds: Codex lists the plugins of a remote marketplace
from a remote catalog request and, when that request fails (the network is
down for a moment), only warns and lists them as missing. A plugin that is
still missing after the last read fails the check.

Codex refreshes configured Git marketplaces in the background when a
session starts and then refreshes the cached copies of their installed
plugins, so a marketplace entry needs no update switch; the minimum still refuses an
older plugin. A marketplace that is not on GitHub (a local path, another Git
host) is added by hand and its plugins are listed without `marketplace`.

Each plugin with `trackAt` adds a `git-compare` row to `dotsteward pins
latest`, with both methods: the row is a review when the marketplace changed
a `watched` path since `observed_marketplace_revision`. After reviewing the
change, move the revision to the commit the row reports (and raise the
minimum when the plugin version moved); `dotsteward-update` does this with
the other pins. The tracking entry can hold the minimum too, as in the
example (`agent_tools.example-plugin.minimum_version`).

Invalid options (an unknown key, a malformed spec, a duplicate, a lock path
that is missing or holds no version, a directory name with a slash, a
tracking entry without a GitHub source or a 40-digit revision, `trackAt`
without `watched` or the reverse) fail the evaluation with every problem
listed. The plugins hook works with both methods.

## Verification

The helper facts were verified on 2026-11-07 from the release `rust-v0.167.0`:
the official `install.sh` (package layout, `$BIN_DIR/codex-code-mode-host` as a
link on darwin only), the assets list, and the real Linux binaries in an
isolated home against a local stand-in for the model API, with
`features.code_mode` on and no account:

- a bare `codex` alone: `failed to spawn code-mode host <dir>/codex-code-mode-host`;
- a bare `codex` with the helper in its directory: the helper starts from there
  and the patch applies;
- a link to `codex` inside the package: the helper starts from the package's
  `bin/`, the directory of the resolved executable;
- `codex sandbox linux` with no `bwrap` on `PATH` and no package: the
  `bubblewrap is unavailable` panic;
- `codex features list`: `code_mode_host` is `stable`, `true` in 0.144.0 and
  every later release tried (0.145.0 to 0.167.0), `under development`, `false`
  in 0.143.0, and absent in 0.142.0. The helper assets first appear in 0.143.0.

darwin was read, not run: both archives hold the one member named after the
asset, and the installer places the helper next to the visible `codex`, which
is this layout.

The facts this component relies on were verified on 2026-10-06 from the
release `rust-v0.160.1`
(<https://github.com/openai/codex/releases/tag/rust-v0.160.1>) and its
assets list (`https://api.github.com/repos/openai/codex/releases/latest`):

- Asset names: verified. `codex-x86_64-unknown-linux-musl.tar.gz` and
  `codex-aarch64-apple-darwin.tar.gz` each hold exactly one member, the
  binary named after the asset without `.tar.gz`; the Linux binary prints
  `codex-cli 0.160.1`. Sizes and SHA-256 digests of the downloaded archives
  equal the digests GitHub publishes for the assets and the values in
  `seed.json`.
- Sigstore: verified, and not used by the installer. The Linux release ships
  `codex-x86_64-unknown-linux-musl.sigstore`, a sigstore bundle in the legacy
  blob format (signature, Fulcio certificate and Rekor entry). It signs the
  extracted binary, not the archive. A sigstore blob verification of the
  binary against that bundle, with certificate identity
  `https://github.com/openai/codex/.github/workflows/rust-release.yml@refs/tags/rust-v0.160.1`
  and OIDC issuer `https://token.actions.githubusercontent.com`, succeeds;
  the same check fails for the archive and for a binary with one appended
  byte. The darwin release ships no sigstore bundle for its archive or
  binary.
- Decision: `verify = "sha256"` on both platforms. The installer checks size
  and SHA-256 from the lock, which binds the exact archive the pin names, and
  verifies the sigstore signature the pin records whenever there is one
  ([docs/pins-engine.md](../../../docs/pins-engine.md#authenticity)):
  `pins apply` finds the member-named bundle next to the Linux archive,
  verifies it, records it and pins the identity on first use, with the tag
  generalized (`...rust-release\.yml@refs/tags/rust-v[0-9]+\.[0-9]+\.[0-9]+$`). `sha256+sigstore` would refuse the darwin pin, which
  has no bundle, and every Linux pin recorded before the signature was, so the
  component does not demand it.

## Files

| File | Purpose |
| --- | --- |
| `default.nix` | the component module (contract values, options validation) |
| `plugins.sh` | the agentsPost hook of the plugins option |
| `e2e-login-path.sh` | the E2E hook `codex-login-path` |
| `e2e-code-mode-host.sh` | the E2E hook `codex-code-mode-host` |
| `skill-hooks.sh` | the agentsPost hook of skill tracking |
| `seed.json` | the release pins `dotsteward init` writes into a new instance |
| `maintenance.md` | update notes |
