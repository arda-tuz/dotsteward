# Locally maintained settings (the logical buffer)

## Contents

1. Model
2. Files and commands
3. States and rules
4. Workflows
5. Decision report

## Model

Many applications write their own settings files while they run. The instance never links or replaces those files. It tracks only the entries listed in the settings buffer, so a change made in an application's settings screen or in the file takes effect immediately on this machine and later reaches the repository through this skill.

The "logical buffer" is the projection of the live files onto the tracked entries. It is computed on every run; there is no copy on disk, no watcher and no background sync. The repository side is `<buffer_dir>/buffer.toml` (the registry plus the last published values) and `<buffer_dir>/files/` (whole-file entries), where `<buffer_dir>` is `settings.buffer_dir` of `dotsteward context --json` (default `local-maintained-files`). Each machine keeps the values of its last published sync in `<state root>/local-maintained-files/base.json`; that base is what tells a local change from a remote one.

Only this skill writes the buffer. `dotsteward-update` never touches it, and the update allowlist never matches `<buffer_dir>/`.

## Files and commands

- Targets come from two sources: the settings targets of the enabled components (rendered for this platform into the manifest mirror `.dotsteward/manifest.<system>.json`, or into the generation's targets file), and `[targets.<name>]` tables in `buffer.toml`. A buffer target replaces a component target of the same name entirely. `target_names` of the context's `settings` lists the names in use.
- A buffer target has `path` (a `~/` string, or `{ linux = "~/...", darwin = "~/Library/..." }`), `format` (`json`, `toml` or `jsonc`), `create_if_missing`, `create_mode`, `backup` and `reload` (a reload hook name of a component, or an inline table with `command`, `timeout`, `env`, `unset_env`, `require_command`, `on_success`, `on_failure`).
- `[[entries]]`: a key entry has `id`, `target`, `key` (list of path segments, leaf or whole table), `value` or `absent = true`, and `note`. A file entry has `kind = "file"`, `path`, `source` (under `files/`) and `mode`. The engine rewrites the entries section in a canonical layout; the header and targets stay as written.
- Machine state under `<state root>/local-maintained-files/`: `base.json`, `journal.jsonl` (every live write with old and new value), `backups/` (full copies before a live file is modified, except targets with `backup = false`, typically files that hold account data) and a lock.
- `dotsteward settings [--repo DIR] [--home DIR] [--state-dir DIR] [--targets-file FILE] <command>`. Defaults: the discovered instance, `$HOME`, the state directory above, and the manifest mirror of this system. The generation's `local-maintained-files` command is the same program with the generation's checkout, state directory and targets file baked in; `dotsteward rebuild` uses it for `apply`.

| Command | Effect | Exit codes |
| --- | --- | --- |
| `status [--json]` | L, R, B and the state of every entry; runs `reconcile` first | 0 |
| `apply` | writes `remote-changed` and `first-contact` entries into live files, never local changes or decisions; runs the target's reload hook after a write; called by the rebuild | 0, 2 on structural errors |
| `flush` | writes `local-changed` entries into the repository buffer (no commit) | 0, 3 when decisions are pending, 2 on errors or guard violations |
| `resolve ID --local` or `resolve ID --remote` | decision for `conflict` or `local-deleted`: the local value to the buffer, or the repository value to the live file | 0, 2 |
| `reconcile` | advances the base where the live value equals the value published on `settings.published_ref` | 0 |
| `verify` | fails on structural errors, `conflict`, `remote-changed` and `first-contact`; `local-changed`, `local-deleted` and `deferred` are notices; run by `dotsteward e2e` | 0, 1 |
| `track --id ID --target T --key a.b` (or `--key-json`) | adds an entry with the current live value | 0, 2 |
| `track-file --id ID --path ~/... --source NAME [--mode 0755]` | adds a whole-file entry and copies the live file into `files/` | 0, 2 |
| `untrack ID` | removes an entry; the live file is not touched | 0, 2 |
| `validate` | static lint of the buffer (schema, keys, paths, guards, uniqueness, `files/` against the file entries) without touching any file | 0, 2 |

## States and rules

L is the live value, R the repository buffer value, B this machine's base.

| State | Condition | `apply` (rebuild) | `flush` |
| --- | --- | --- | --- |
| `in-sync` | L = R | nothing | nothing |
| `local-changed` | L != B, R = B | nothing | writes L |
| `local-deleted` | L absent, R = B | nothing | waits for a decision |
| `remote-changed` | L = B, R != B | writes R | reports |
| `conflict` | L != B, R != B, L != R | nothing (`verify` fails) | waits for a decision |
| `first-contact` | no base, L != R | writes R (the repository wins, with a backup) | reports |
| `deferred` | target missing and `create_if_missing = false` | nothing | nothing |
| `error` | symlinked, unreadable, non-UTF-8 or unparsable target, or a JSONC file with comments or trailing commas | stops before any write | stops |

- Values compare by type: `true` differs from `1`, `50` from `50.0`; formatting and key order do not count. Absence is a value, so confirming a local deletion removes the entry's value on every machine.
- The base only advances to values published on `settings.published_ref`; an unpublished commit never becomes a base.
- Non-interactive paths (the rebuild, the E2E checks) never decide; decisions happen only in this skill, and only on the user's answer.
- Guards: key paths containing token, secret, password, credential, oauth, bearer, API key or private key are refused; values and file contents must not contain an absolute home path (use `~` or `$HOME`).
- Writes are atomic (same-directory temporary file and rename), keep the file mode, re-read and verify, and never follow a symlink. TOML is edited in place, so comments and untouched lines stay as they are; whole tables are synchronized key by key. A JSONC target is written like JSON and only when it has no comments.

## Workflows

Run every command from the instance checkout after the Start section of `SKILL.md` (`git pull --ff-only` first when `HEAD` is behind the remote branch).

**Write local settings to the repository** (the user asks for it, or accepts pending entries found at the start of another transaction):

1. Read the state of every entry:

   ```bash
   dotsteward settings status --json
   ```

2. If any entry has `needs_decision`, produce the decision report (below), wait for the user's answer, and record it for each entry:

   ```bash
   dotsteward settings resolve ID --local
   ```

   (`--remote` instead when the user keeps the repository value.)
3. Write the local changes into the buffer; repeat step 2 if it exits with 3:

   ```bash
   dotsteward settings flush
   ```

4. `git add -A`, then the gate (`dotsteward gate --scope maintain`), then a commit with `commit.settings_subject` of the context (or include the change in the transaction's own commit).
5. Rebuild, E2E and `dotsteward update publish --scope maintain` as in `SKILL.md`, then advance this machine's base:

   ```bash
   dotsteward settings reconcile
   ```

6. Report each entry with its old and new repository value.

**Track or untrack**: `dotsteward settings track`, `dotsteward settings track-file` or `dotsteward settings untrack` in the transaction, `dotsteward settings validate`, then gate, commit, rebuild, E2E, publish and `dotsteward settings reconcile`. Refuse secrets, credentials, account state, caches and machine-specific paths. When an application renames a key, the old entry shows up as `local-deleted`; move the entry to the new key with `untrack` and `track`. A target that no component declares needs a `[targets.<name>]` table in `buffer.toml` first; a target every user of a catalog component would want belongs in the framework (`dotsteward-contribute`).

**Change a value for every machine from the repository**: edit the entry's `value` in `buffer.toml` within the transaction; on this machine the next rebuild sees `remote-changed` and applies it.

## Decision report

Use it for every entry with `needs_decision` (`conflict` and `local-deleted`). First-contact differences are not asked: the repository wins.

Give the report as plain text (a table per entry is fine) unless the overlay asks for another format, then wait for the user's reply. For each entry show:

- the ID, the application and file (the target and its path) and the key path (or the file path), and the entry's note;
- the local value (L), the repository value (R) and the last synchronized value (B);
- when each side changed: the live file's modification time (`live_modified`) and the commit that last changed the buffer (`repo_last_change` of `status --json`);
- for whole files, the diff between the local file and `<buffer_dir>/files/<source>`;
- a recommended choice with its reasoning, and the options: keep local (`resolve --local`), take the repository value (`resolve --remote`), or another value (edit the live file, then `flush`).

Act only on the user's answer; never resolve a decision silently.
