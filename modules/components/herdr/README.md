# herdr

The herdr terminal workspace manager, installed by Home Manager from the
upstream herdr flake.

Enable it in `workstation.toml`:

```toml
[components.herdr]
enable = true
```

## Install

| Platform | Method | What is installed |
| --- | --- | --- |
| Linux | `nix` (the only supported method) | `inputs.herdr.packages.<system>.herdr` in the Home Manager profile |
| darwin | `nix` (the only supported method) | the same package, built for the darwin system |

The package comes from the instance flake input `herdr`, so the version is
the one `flake.lock` records. `dotsteward init` writes the input between the
`# dotsteward:inputs:begin` and `# dotsteward:inputs:end` markers of
`flake.nix` and merges the seed (`seed.json`) into `versions.lock.json`. An
instance that enables herdr without the input fails to build with a message
that names the line to add:

```nix
inputs.herdr.url = "github:herdrdev/herdr/v0.9.3";
```

The other contract values (settings target, probes, pins) do not need the
input, so the manifest of an instance is still readable while the input is
being added.

## Settings

herdr writes its own configuration file while it runs, so Home Manager never
links or replaces it. The component declares one settings target for the
local-maintained-files engine:

| Target | Path (Linux and darwin) | Format | Missing file | Backup | Reload |
| --- | --- | --- | --- | --- | --- |
| `herdr` | `~/.config/herdr/config.toml` | TOML | created, mode 0644 | yes | `herdr-server` |

Only the entries an instance tracks in `local-maintained-files/buffer.toml`
with `target = "herdr"` are synchronized; every other setting in the file
stays as herdr wrote it. Example:

```toml
[[entries]]
id = "herdr-onboarding"
target = "herdr"
key = ["onboarding"]
value = false
```

After the engine writes the file it runs the reload hook `herdr-server`:
`herdr server reload-config`, with a 15 second timeout, `HOME` and
`XDG_CONFIG_HOME` set to the target home (herdr reads
`$XDG_CONFIG_HOME/herdr` before `~/.config/herdr`) and `HERDR_SOCKET_PATH`
removed, so a value inherited from a herdr pane cannot address another
server. The hook runs only when `herdr` is on `PATH`; success is logged, and a
failure (usually: no server is running) is silent, since the next server
start reads the new file anyway.

herdr also honours `HERDR_CONFIG_PATH`, which points it at another file. The
settings target always manages `~/.config/herdr/config.toml`; a machine that
sets `HERDR_CONFIG_PATH` does not see the synchronized entries.

`~/.config/herdr/config.toml` is in the bootstrap backup paths. Rollback
leaves it in place: it is user data, not a Home Manager link.

## Checks

- Probe: `herdr --version` must run (presence).
- E2E: `herdr` is a required command, and when the `shell` component is
  enabled, the hook `herdr-login-zsh` checks that an interactive login zsh
  finds `herdr` on `PATH`.

## Pins

- Flake input `herdr`; `versions.lock.json` records it under
  `flake_inputs.herdr` (reference, revision, version, NAR hash).
- Rule: `nix_packages.herdr.expected` is derived from
  `flake_inputs.herdr.version`.
- Latest: GitHub releases of `herdrdev/herdr`.
- Resolved version: the version of the input's package.

## Verification status

- darwin settings path: verified on 2026-10-06 from the upstream source at
  `herdrdev/herdr` v0.9.3 (`src/config/io.rs`: outside Windows the
  configuration directory is `$XDG_CONFIG_HOME/herdr`, else
  `$HOME/.config/herdr`, with no macOS-specific location) and the upstream
  configuration documentation ("Linux and macOS: ~/.config/herdr/config.toml").
  The settings target therefore uses one path on both platforms.
- darwin package: the upstream flake declares `packages.<system>.herdr` for
  `x86_64-darwin` and `aarch64-darwin` (verified on 2026-10-06 from
  `flake.nix` at v0.9.3); a darwin build is not verified on this machine.
- `herdr server reload-config`: verified on 2026-10-06 from the upstream
  source at v0.9.3 (the command herdr itself prints after a configuration
  change).
