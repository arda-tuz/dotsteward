# Private components

A component is one application or tool with everything that makes it
reproducible: how it is installed on each platform, which versions are pinned,
which settings files it owns, what is backed up and rolled back, and how its
installation is checked. The framework ships the catalog components (`shell`,
`herdr`, `claude-code`, `codex`, `opencode-pi`, `vscode`); anything else lives
here as a private component of this instance.

Each private component is a directory `components/<name>/`:

| File | Content |
| --- | --- |
| `default.nix` | A Home Manager module that sets `dotsteward.components.<name>` (the component contract) and any ordinary Home Manager options. |
| `package.nix` | Optional. Packages built with Nix: a function of `{ pkgs, pins, inputs, system, lib, packages, ... }` returning an attribute set; each attribute joins the instance package set (`packages.<name>`). |
| `README.md` | Optional. What the component installs and how to maintain it. |
| scripts | Hooks and E2E checks the module refers to (`script = ./check.sh;`). |

A component is used only when `workstation.toml` enables it with a
`[components.<name>]` table:

```toml
[components.example-term]
enable = true
# Optional: method = "external", profiles = ["workstation"], options = { ... }
```

## The example

`components/example/default.nix.disabled` is an annotated example of the full
contract for a synthetic `example-term` installed from official release
archives. Its suffix keeps it out of the instance. To try it:

1. Copy it to `components/example-term/default.nix`.
2. Add a `[components.example-term]` table with `enable = true` to
   `workstation.toml`.
3. Add its release pins to `versions.lock.json`, one per platform of
   `[nix] systems`, at the lock path its rules read
   (`agent_tools.example-term.linux`, `agent_tools.example-term.darwin`):

   ```json
   "agent_tools": {
     "example-term": {
       "linux": {
         "version": "1.4.0",
         "url": "https://github.com/example-org/example-term/releases/download/v1.4.0/example-term-x86_64-linux.tar.gz",
         "size": 1048576,
         "sha256": "<sha256 of the archive>"
       }
     }
   }
   ```

4. Run `git add -A`, then `dotsteward sync` to refresh the `.dotsteward/`
   mirrors, and `dotsteward pins check` and `dotsteward static`.

A real component replaces the names, release locations and paths with those of
its application, keeps the fields it needs and drops the empty ones (every
field has a default).

## Writing a component

The `dotsteward-maintain` skill adds, changes and removes components for you
and validates the result with the gate. To write one by hand, read
`docs/writing-components.md` and `docs/component-contract.md` in the dotsteward
framework repository, start from the example and keep these rules:

- Contract values (`dotsteward.components.<name>`) never depend on the
  profile; scope the component with `profiles` in `workstation.toml` instead.
  Ordinary Home Manager options may depend on `profile`.
- Versions, URLs and hashes live in `versions.lock.json`, never in Nix files;
  declare pin rules so `dotsteward pins check` verifies them and latest
  declarations so `dotsteward pins latest` researches updates.
- Settings files the application rewrites itself are settings targets of the
  local maintained files engine, not Home Manager links.
- Nix sees only tracked files: `git add -A` before any Nix command.
