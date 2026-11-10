# apt-policy

The system files that bind the other drivers of apt (unattended-upgrades, the
software updaters, a plain `apt upgrade`) to what `dotsteward upgrade` does with the
kernel and driver classes. Linux only, method `system`.

It is enabled by default on every instance with a Linux system, without a line in
`workstation.toml`: the "no removals" rule of the gated classes is the framework's, and the
apt engine wrote the drop-in itself before the component took it over. The one way out:

```toml
[components.apt-policy]
enable = false
```

## Install

| Platform | Method | What is installed |
| --- | --- | --- |
| Linux | `system` (the only supported method) | `/etc/apt/apt.conf.d/52dotsteward-unattended-upgrades`, root-owned, mode 0644 |
| darwin | none | not available: the component is left out on darwin |

The drop-in keeps unattended-upgrades from removing kernels and dependencies on its
own:

```text
// Managed by dotsteward: no automatic removal of kernels and dependencies.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
```

These are the bytes that `dotsteward upgrade` wrote before the component took the
file over, so a machine that has it already needs no write. `dotsteward install` writes it on every profile, adopted ones too, and so does `dotsteward
upgrade` in its sudo window when the file is missing or differs. Without the component,
`dotsteward upgrade` says that unattended-upgrades may remove kernels by itself. The pin file of the gated classes
(`/etc/apt/preferences.d/60dotsteward`) and its dpkg hook are not part of the
component: they follow what dpkg has, so `dotsteward upgrade` writes them
([docs/upgrade.md](../../../docs/upgrade.md)).

## Checks

| Check | What it verifies |
| --- | --- |
| `dotsteward install --check-only` | the bytes and the mode of the drop-in |
| E2E `unattended-upgrades` | `apt-config` reads both keys as `false`, so no later file of `apt.conf.d` sets them back; without the drop-in it names the install step and passes |

## Removal

Disabling the component leaves the drop-in in place; remove it with `sudo rm
/etc/apt/apt.conf.d/52dotsteward-unattended-upgrades`.
