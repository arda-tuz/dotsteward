# vscode

VS Code from the vendor's official builds, its user settings file as a settings target, and optionally VS Code as the default editor.

Enable it in `workstation.toml`:

```toml
[components.vscode]
enable = true
options = { set_default_editor = true }
```

## What it installs

| Platform | Default method | Also supported | Pin (`versions.lock.json`) |
| --- | --- | --- | --- |
| Linux (x86_64) | `deb` | `external` | `desktop_packages.vscode` |
| darwin (aarch64) | `app-archive` | `external` | `desktop_packages.vscode-darwin-arm64` |

Choose a method with `method = "..."` or `method_by_platform = { linux = "...", darwin = "..." }` in `[components.vscode]`.

- `deb` (Linux): the official DEB of package `code` (architecture `amd64`), downloaded from the pinned URL and verified by size and SHA-256 before anything is installed. In a `fresh` profile, `dotsteward install` adds it to the single apt transaction only when the installed `code` is older than `minimum_version`; a newer installed version is kept, never downgraded. The package's installer asks whether to add the vendor's apt repository; dotsteward never answers that question for you and never removes that repository, so VS Code keeps updating itself through it. `--check-only` compares the installed version with `minimum_version` (`dpkg --compare-versions`). In an `adopt` profile VS Code is not managed.
- `app-archive` (darwin): the official arm64 archive, a zip whose root is the bundle `Visual Studio Code.app`, verified by size and SHA-256 and installed as `~/Applications/Visual Studio Code.app` (an existing bundle is backed up first). The installed version is the `CFBundleShortVersionString` of `Visual Studio Code.app/Contents/Info.plist`; it must be at least `minimum_version`, and a newer bundle (VS Code updates itself on macOS) is kept. The bundle's command line launcher, `Contents/Resources/app/bin/code`, is put on `PATH` through Home Manager's session variables, so `code` works in your shells. In an `adopt` profile VS Code is not managed.
- `external`: you install VS Code yourself; dotsteward expects `code` on `PATH` and installs nothing.

Both pins hold `minimum_version`, `url`, `size` and `sha256`. The URL is the update service's version-addressed download, `https://update.code.visualstudio.com/<version>/linux-deb-x64/stable` and `https://update.code.visualstudio.com/<version>/darwin-arm64/stable`, and the pins check (`dotsteward pins check`) requires exactly that form. `dotsteward pins latest` compares each pin with the update service's newest stable build (`official-manifest` adapter, see `maintenance.md`). `dotsteward init` starts a new instance from `seed.json`.

## Settings target

| Target | Format | Linux path | darwin path |
| --- | --- | --- | --- |
| `vscode-settings` | JSONC | `~/.config/Code/User/settings.json` | `~/Library/Application Support/Code/User/settings.json` |

Track a setting with the settings engine (`dotsteward settings track`, or an `[[entries]]` table with `target = "vscode-settings"` in `local-maintained-files/buffer.toml`). Setting names contain dots and are one key each, for example `key = ["editor.fontSize"]`. The file is created (mode 0644) when a tracked entry needs it and does not exist, and it is backed up before the first write. VS Code reloads the file itself, so there is no reload hook.

The settings engine reads JSONC but writes plain JSON: when your `settings.json` contains comments or trailing commas, every entry of the target is reported as an error and `apply` refuses before writing anything. Remove the comments (or change the setting in VS Code) and run it again.

## Options

| Option | Type | Default | Effect |
| --- | --- | --- | --- |
| `set_default_editor` | boolean | `false` | `true` sets exactly `EDITOR = "code"`, `VISUAL = "code"` and `GIT_EDITOR = "code --wait"` (Home Manager `home.sessionVariables`) in every profile where the component is active. `GIT_EDITOR` uses `code --wait`, so Git waits until you close the editor tab. |

Any other option, or a value that is not a boolean, fails the evaluation with a message naming it.

The component adds no probe, E2E command, hook, backup path or managed link: the application owns its files, and the settings target is backed up by the settings engine.

## Verification (catalog facts, SPEC section 14)

- darwin `app-archive` download URL and version key: verified on 2026-10-06 from the official update API (`https://update.code.visualstudio.com/api/update/darwin-arm64/stable/latest`, `productVersion` 1.140.0). The version-addressed URL `https://update.code.visualstudio.com/1.140.0/darwin-arm64/stable` redirects to the API's file `VSCode-darwin-arm64.zip`; the download's size (317901801 bytes) and SHA-256 equal the pin and the API's `sha256hash`; its root is `Visual Studio Code.app`, whose `Contents/Info.plist` has `CFBundleShortVersionString` 1.140.0 (equal to `productVersion`), and the launcher is `Contents/Resources/app/bin/code`. The `app-archive` method is therefore enabled on darwin (the fallback, `external` only, is not needed).
- Linux `deb`: verified on 2026-10-06 from the same API (`linux-deb-x64`): the version-addressed URL redirects to the API's file, its size (241278114 bytes) and SHA-256 equal the pin and `sha256hash`, and its control fields are `Package: code`, `Architecture: amd64`, `Version: 1.140.0-<build>`.
- JSONC handling of the settings file: verified by the settings engine's tests with commented fixtures (P2-15) and by this component's end-to-end settings test.
