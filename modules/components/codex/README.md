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
| Linux (x86_64) | `official-binary` | `codex-x86_64-unknown-linux-musl` from the release archive `codex-x86_64-unknown-linux-musl.tar.gz`, installed as `~/.local/bin/codex` (mode 0755) |
| darwin (aarch64) | `official-binary` | `codex-aarch64-apple-darwin` from the release archive `codex-aarch64-apple-darwin.tar.gz`, installed as `~/.local/bin/codex` (mode 0755) |

Both archives come from the official GitHub releases of `openai/codex`
(tags `rust-v<version>`). The pins live in `versions.lock.json` under
`agent_tools.codex.linux` and `agent_tools.codex.darwin`, each with
`version`, `url`, `size` and `sha256`; `dotsteward init` writes them from
`seed.json`. Only the platforms of `nix.systems` whose method is
`official-binary` declare pins.

The installer runs at user level (no root) during `dotsteward rebuild
--switch` and `dotsteward agents install`:

1. download the pinned archive over HTTPS (TLS 1.2 or newer);
2. compare its size, then its SHA-256, with the pin, and refuse it on any
   difference before anything is replaced;
3. extract the single member and install it at `~/.local/bin/codex`;
4. read the version from `codex --version` (`codex-cli <version>`).

The policy is `at-least`: a binary that reports the pinned version or a
newer one is kept (Codex may update itself), an older one is replaced, and
the pin is never downgraded. A symlink at `~/.local/bin/codex` is refused.
`dotsteward install --check-only` and `dotsteward agents check` report a
missing or older binary with the rebuild hint and change nothing.

## Methods

| Method | Platforms | Behaviour |
| --- | --- | --- |
| `official-binary` | linux, darwin | the verified release archive above (default) |
| `external` | linux, darwin | nothing is installed; `codex` must be on `PATH` (installed by any other means), and the checks fail when it is not |

`external` declares no pins.

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

## Plugins

`options.plugins` lists Codex plugins to install and verify, one
`[[components.codex.options.plugins]]` table per plugin:

```toml
[components.codex]
enable = true

[[components.codex.options.plugins]]
spec = "example-plugin@example-market"
minimumAt = "agent_tools.example-plugin.minimum_version"
requiredSkillDirectories = ["alpha", "beta"]
```

The inline form `options = { plugins = [ { spec = "..." }, ... ] }` is
equivalent, but TOML 1.0 requires each inline table on a single line.

| Key | Required | Meaning |
| --- | --- | --- |
| `spec` | yes | `NAME@MARKETPLACE`, as `codex plugin add` takes it |
| `minimumAt` | no | a `versions.lock.json` path holding the minimum version: a version string, or an entry with `minimum_version` or `version` |
| `requiredSkillDirectories` | no | directory names that must hold `skills/<name>/SKILL.md` inside the installed plugin |

A non-empty list adds the `plugins` hook (`plugins.sh`, an agentsPost hook:
agents phase, before validation). `dotsteward agents install` runs `codex plugin add SPEC`
for each plugin that `codex plugin list --json` does not show installed and
enabled. Both `agents install` and `agents check` then verify every plugin:

- it is listed as installed and enabled, with a plain version string;
- its directory (the listed local source path, else
  `${CODEX_HOME:-~/.codex}/plugins/cache/<marketplace>/<name>/<version>`)
  holds `.codex-plugin/plugin.json` with the same version;
- the version is at least the lock minimum; an older plugin fails and is
  never upgraded silently;
- every required skill directory has a `SKILL.md`.

`agents check` never installs anything. Invalid options (an unknown key, a
malformed spec, a duplicate, a lock path that is missing or holds no
version, a directory name with a slash) fail the evaluation with every
problem listed. The plugins hook works with both methods.

## Verification

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
  and SHA-256 from the lock, which binds the exact archive the pin names.
  Sigstore would cover Linux only, would verify the member after extraction
  rather than the download, and needs a sigstore client on the machine;
  `sha256+sigstore` is not implemented by the official-binary method yet.

## Files

| File | Purpose |
| --- | --- |
| `default.nix` | the component module (contract values, options validation) |
| `plugins.sh` | the agentsPost hook of the plugins option |
| `seed.json` | the release pins `dotsteward init` writes into a new instance |
| `maintenance.md` | update notes |
