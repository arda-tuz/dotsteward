# Privacy

dotsteward manages private workstations from a public framework. Two
promises follow: nothing about any user ever enters the framework, and
nothing in your instance is published unless you publish it. This page
describes the layers that keep those promises and the scanner they rely
on.

## Layers

| Layer | Mechanism |
| --- | --- |
| No room for user data in the framework | Identity, values and private components live in the instance; the framework reads them at run time. |
| Synthetic fixtures | Tests use invented users, paths and applications; secret-shaped strings are assembled at run time by `fake_secret` in `tests/lib/harness.sh`, so no secret-shaped literal is ever committed. |
| Generic scan | `dotsteward scan` checks the tree, the staged index and pushed commits for secrets, home paths, e-mail addresses, private IP addresses and non-ASCII text. |
| Private denylist | Each maintainer keeps a denylist of private terms outside every repository; the pre-push hook and CI match it. |
| Commit metadata | Framework commits use a GitHub noreply address, UTC dates and no generated trailers. |
| Instance-leak scan | `dotsteward contribute check` also scans for values of the contributor's own instance ([contribute.md](contribute.md#the-framework-gate)). |
| Command-name rule | Framework code, tests and docs name only catalog applications, platform tools and synthetic examples. |
| Nothing bundled | No third-party skills, no npm package, no telemetry. |

## The policy file

`privacy/policy.toml` is the framework's public policy:

| Key | Meaning |
| --- | --- |
| `schema_version` | `1`. |
| `generic_secrets` | Private keys, cloud and forge tokens, and credential assignments. |
| `home_paths` | Home directory paths; `allow_users` and `allow_paths` list the synthetic ones tests use. |
| `emails` | E-mail addresses; `allow_domains` and `allow_exact` list the reserved and noreply ones. |
| `private_ipv4` | Private IPv4 addresses. |
| `non_ascii` | Any byte of 0x80 or above in a text file, which catches text in other languages; `except_files` exempts files. |
| `forbidden_paths` | Paths that must never be tracked, such as local tool state and `.env` files. |
| `commits` | The commit rules (applied with `--metadata`). |
| `commits.email` | The pattern author and committer e-mail addresses must match: a GitHub noreply address. |
| `commits.utc_only` | Author and committer dates must use the `+0000` offset. |
| `commits.forbidden_lines` | Message lines that are refused, such as co-author and generated-by trailers. |
| `denylist` | The private denylist. |
| `denylist.path` | Its default location, `~/.config/dotsteward/denylist.txt`. |
| `denylist.required_for_range` | Commit range scans in the hook refuse to run without it. |

`privacy/allowlist.txt` lists public strings (the framework's commit
identity and repository name). Extra terms are matched after they are
masked; the generic rules still see them. An allowlist entry never hides a
denylist term: a scan refuses an entry that contains one, naming the
allowlist and denylist line numbers, unless the entry is a commit e-mail
address that `commits.email` accepts (every commit carries that address,
so it is public by policy). Denylist terms are matched after only those
addresses are masked.

An instance has its own, smaller policy: the `[privacy]` table of
`workstation.toml` ([workstation-toml.md](workstation-toml.md)) adds
forbidden paths, file rules and an optional denylist to the generic secret
rules. Instance content is personal by design, so the home path, non-ASCII
and commit rules do not apply there.

## The scanner

```sh
dotsteward scan --tree --redact
dotsteward scan --staged
dotsteward scan --range origin/main..HEAD --metadata --require-denylist --redact
```

| Mode | What it reads |
| --- | --- |
| `--tree` | every file Git can see (tracked and untracked, not ignored); outside Git every file below the current directory |
| `--staged` | the index blobs of the next commit |
| `--range RANGE` | every commit of the range: the blobs it changed, its message, author and committer, and annotated tags in the range |

| Option | Effect |
| --- | --- |
| `--metadata` | also apply the commit rules (`--range` only) |
| `--denylist F` | match private terms from F |
| `--require-denylist` | refuse to run without a denylist; without `--denylist` the policy's path is used |
| `--extra-terms F` | match more terms in the same format |
| `--redact` | print the rule and the location only, never the matched text |

A denylist has one term per line: a plain line matches as a
case-insensitive substring, `word:TERM` as a whole word, `re:ERE` as an
extended regular expression, and `#` starts a comment. Findings print as
`<rule> <file>:<line>` or `<rule> commit <sha> <field>`; a denylist finding
names the line of the denylist, never the term. The scanner collects every
finding and exits 1 when there is at least one, 0 when the scan is clean.

## Where scans run

- **Pre-push hook** (`.githooks/pre-push`, enabled by
  `git config core.hooksPath .githooks`; `dotsteward contribute setup`
  sets it in your framework clone): every pushed commit with the metadata
  rules and the denylist, and the tree of the pushed tip. Without the
  denylist it refuses to push.
- **CI** (`.github/workflows/privacy.yml`): the generic rules on every
  pull request and push; the denylist, stored as a repository secret, only
  on pushes to `main` and manual runs, never for pull requests from forks.
- **The gate** of an instance runs the instance policy over the instance
  tree before every publish.
- **`dotsteward contribute check`** runs the tree, range and instance-leak
  scans before anything leaves your machine; any finding stops the run
  with exit status 4.

## Rules for framework text

Code, tests, fixtures, docs and commit messages may name only the catalog
applications (Claude Code, Codex, herdr, zsh and starship, OpenCode and Pi,
VS Code), the platform tools the framework itself uses, generic concepts,
and synthetic examples such as `example-term` and `example-app`. They never
contain personal data: real names, e-mail addresses, home paths, host
names, tokens or the names of other applications someone uses.

## Reporting a leak

If you find personal data or a secret in the framework, report it
privately as described in [SECURITY.md](../SECURITY.md); do not open a
public issue that repeats it.
