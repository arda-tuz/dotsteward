# Settings buffer

Many applications rewrite their own settings files while they run, so those
files cannot be read-only links into the Nix store. dotsteward leaves them
as normal user files and tracks only the keys (or whole files) you choose,
in the **settings buffer** of the instance. The settings engine,
`dotsteward settings`, keeps the buffer and the live files in step with a
three-way merge. This page is the reference; [concepts.md](concepts.md#settings-buffer)
has the short version.

## Model

For every tracked entry the engine compares three values:

| Value | Where it lives |
| --- | --- |
| **L**, the live value | the application's file on this machine |
| **R**, the repository value | the buffer in the instance checkout |
| **B**, the base | the last value this machine synchronized, in its state directory |

The base tells a local change from a remote one. It only advances to
values published on `settings.published_ref` (by default
`origin/<instance.branch>`), so an unpublished commit never becomes a base.
There is no copy of the live files, no watcher and no background sync: the
engine computes the state on every run.

## Files

The buffer is the directory `settings.buffer_dir` of `workstation.toml`
(default `local-maintained-files/`):

- `buffer.toml` holds the registry: optional `[targets.<name>]` tables and
  one `[[entries]]` table per tracked key or file, with the last published
  value.
- `files/` holds the content of whole-file entries.

Machine state lives in `<state root>/local-maintained-files/`: `base.json`,
`journal.jsonl` (every live write with its old and new value), `backups/`
(a full copy before a live file is first modified, except for targets
with `backup = false`) and a lock file.

## Targets

A target is one settings file. Targets come from two sources:

1. The `settingsTargets` of every enabled component, rendered for the
   current platform into the manifest (see
   [component-contract.md](component-contract.md#settings)).
2. `[targets.<name>]` tables in `buffer.toml`, for files no component
   declares. A buffer target replaces a component target of the same name
   as a whole; fields are never merged.

```toml
[targets.example-term]
path = { linux = "~/.config/example-term/config.toml", darwin = "~/Library/Application Support/example-term/config.toml" }
format = "toml"
create_if_missing = true
create_mode = "0644"
backup = true
reload = { command = ["example-term", "reload"], timeout = 15, require_command = "example-term", on_failure = "warn" }
```

`reload` is either the name of a component's reload hook or an inline table
with `command`, `timeout`, `env`, `unset_env`, `require_command`,
`on_success` and `on_failure`; `{home}` in the command expands to the home
directory. A reload runs at most once per hook and run, and only after a
write.

Supported formats are JSON, TOML and JSONC. TOML is edited in place, so
comments and untouched lines stay. A JSONC file is read with its comments
and trailing commas stripped, but written like JSON, so when it contains
any comment or trailing comma every entry of that target is an error and
nothing is written.

## Entries

```toml
[[entries]]
id = "example-term-theme"
target = "example-term"
key = ["appearance", "theme"]
value = "dark"
note = "Dark theme everywhere."

[[entries]]
id = "example-term-keys"
kind = "file"
path = "~/.config/example-term/keys.conf"
source = "example-term-keys.conf"
mode = "0644"
```

- A **key entry** names a target and a key path (a list of segments; the
  last one may be a leaf or a whole table) and holds `value`, or
  `absent = true` when the key must not exist.
- A **file entry** (`kind = "file"`) copies a whole file from
  `files/<source>` with the given mode.
- The engine rewrites the entries section in a canonical layout; the
  header and the targets stay as you wrote them.

## Commands

All commands run from the instance checkout; `--repo`, `--home`,
`--state-dir` and `--targets-file` override the defaults (see
[cli.md](cli.md#settings)).

| Command | Effect |
| --- | --- |
| `dotsteward settings status [--json]` | The state of every entry with L, R and B; reconciles first. |
| `dotsteward settings apply` | Writes `remote-changed` and `first-contact` entries into the live files and runs reload hooks. `dotsteward rebuild` runs it after activation. |
| `dotsteward settings flush` | Writes `local-changed` entries into the buffer (no commit). |
| `dotsteward settings resolve ID --local` | Decides a conflict or a local deletion for the local value; `--remote` takes the repository value. |
| `dotsteward settings reconcile` | Advances the base where the live value equals the published value. |
| `dotsteward settings verify` | Fails when this machine disagrees with the repository; `dotsteward e2e` runs it. |
| `dotsteward settings track --id ID --target T --key a.b` | Starts tracking a key with its current live value (`--key-json` for keys that contain dots). |
| `dotsteward settings track-file --id ID --path ~/... --source NAME` | Starts tracking a whole file and copies it into `files/` (`--mode` sets its mode). |
| `dotsteward settings untrack ID` | Stops tracking an entry; the live file is not touched. |
| `dotsteward settings validate` | Lints the buffer without touching any file. |

Exit codes: 0 success; 1 `verify` found a difference; 2 an error or a guard
violation; 3 a decision is pending (`flush` stops until you `resolve` it).

## States

| State | Condition | `apply` (rebuild) | `flush` |
| --- | --- | --- | --- |
| `in-sync` | L = R | nothing | nothing |
| `local-changed` | L differs from B, R = B | nothing | writes L |
| `local-deleted` | L absent, R = B | nothing | waits for a decision |
| `remote-changed` | L = B, R differs from B | writes R | reports |
| `conflict` | L, R and B all differ | nothing; `verify` fails | waits for a decision |
| `first-contact` | no base yet, L differs from R | writes R, after a backup | reports |
| `deferred` | the target is missing and is not created | nothing | nothing |
| `error` | the target is a symlink, unreadable, not UTF-8, unparsable, or JSONC with comments | stops before any write | stops |

Local changes therefore win until you flush them; published changes arrive
with the next rebuild; a conflict or a deletion always waits for your
decision. Non-interactive paths (rebuild, end-to-end checks) never decide.

## Guarantees and guards

- Values compare by type: `true` differs from `1` and `50` from `50.0`;
  formatting and key order do not count. Absence is a value.
- Writes are atomic (a temporary file in the same directory, renamed over
  the target), keep the file mode, are read back and verified, and never
  follow a symlink. Concurrent runs wait for the engine's lock.
- Key paths that look like credentials (token, secret, password,
  credential, OAuth, bearer, API key, private key) are refused, and values
  and files must not contain an absolute home path; write `~` or `$HOME`.
- An update-scope transaction may never change the buffer
  ([update-policy.md](update-policy.md)); only the maintain skill writes it.

## Typical flows

Write local changes back to the repository:

```sh
dotsteward settings status --json
dotsteward settings resolve example-term-theme --local   # only for decisions
dotsteward settings flush
git add -A
dotsteward gate --scope maintain
```

Then commit, publish and run `dotsteward settings reconcile` so this
machine's base advances. Change a value for every machine by editing its
`value` in `buffer.toml`; each machine applies it as `remote-changed` on
its next rebuild.
