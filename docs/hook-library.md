# The hook library

A component hook is a script that the framework starts during install,
rebuild, the agents phase or the end-to-end checks
([component-contract.md](component-contract.md)). Hooks in instances live for
years, so the bash library they use is frozen as version 1: no function is
removed, renamed or added, and a function keeps its arguments, output and exit
status. A body changes only to fix a bug. `tests/cli/lib/test-hook-contract.sh`
holds the library to this page.

New shared code goes into the Python package ([python.md](python.md)), not
into this library.

## The environment

A hook runs with these variables:

| Variable | Value |
| --- | --- |
| `DOTSTEWARD_LIB` | the directory of the library; a hook sources `$DOTSTEWARD_LIB/lib.sh` |
| `DOTSTEWARD_INSTANCE` | the instance root |
| `DOTSTEWARD_STATE_ROOT` | the machine state root |
| `DOTSTEWARD_PROFILE`, `DOTSTEWARD_PROFILE_MODE` | the profile and its mode |
| `DOTSTEWARD_PLATFORM` | `linux` or `darwin` |
| `DOTSTEWARD_COMPONENT` | the component of the hook |
| `DOTSTEWARD_CHECK_ONLY` | `1`: change nothing |
| `DOTSTEWARD_ASSUME_YES` | `1`: answer yes to the package manager |

`DOTSTEWARD_LIB` is the library of the CLI that runs the hook, which can be
older than the hook.

## lib.sh

Sourcing `lib.sh` turns on `set -Eeuo pipefail` in the hook, prints nothing and
loads the platform layer.

| Purpose | Functions |
| --- | --- |
| Messages | `log`, `warn`, `die` |
| Requirements | `require_command`, `require_profile`, `require_safe_identity`, `current_platform` |
| The user's `PATH` | `user_path`, `user_run`, `user_login_zsh` |
| Files | `timestamp_utc`, `ensure_private_dir`, `sha256_file`, `directory_sha256`, `install_asset`, `forbid_paths` |
| Locks | `lock_value`, `pin_value`, `desktop_pin` |
| Network | `git_net`, `download_https`, `download_verified` |
| Nix | `source_nix_daemon`, `nix_cmd` |
| State | `state_root`, `cleanup_temp_dir`, `backup_file_private`, `backup_copy_of` |
| Login shell | `stable_zsh_path`, `ensure_stable_login_shell` |

The comments of `cli/lib/lib.sh` document each function.

## The platform layer

`lib.sh` loads it for the running platform ([platforms.md](platforms.md#the-platform-layer)).

| Platform | Functions |
| --- | --- |
| Both | `platform_os_id`, `platform_os_version`, `platform_architecture`, `platform_shells_file`, `platform_shells_contains`, `platform_shells_add`, `platform_shells_remove`, `platform_login_shell`, `platform_set_login_shell` |
| Linux | `os_release_value`, `dpkg_installed`, `dpkg_version`, `dpkg_version_at_least`, `package_provides`, `deb_field`, `apt_update`, `apt_install` |
| darwin | `sw_vers_value`, `xcode_clt_installed`, `require_xcode_clt`, `app_bundle_version`, `platform_app_archive_check`, `platform_app_archive_install` |

## config.sh and methods.sh

A hook that needs the instance configuration sources `config.sh` after
`lib.sh` and calls `config_load`: `config_query`, `config_instance_path`,
`config_profile_mode`, `config_component_active` and the `DS_*` variables that
the comments of `cli/lib/config.sh` list.

`methods.sh` is the engine of the install methods, sourced after `config.sh`.
It may grow, but these stay: `methods_system`, `methods_manifest_load`,
`methods_components`, `methods_component`, `methods_component_method`,
`methods_is_system_level`, `methods_validate`, `methods_lock_get`,
`methods_version_compare`, `methods_version_at_least`,
`methods_extract_version`, `methods_check`, `methods_hooks`,
`methods_hook_path`, `methods_run_hook`.
