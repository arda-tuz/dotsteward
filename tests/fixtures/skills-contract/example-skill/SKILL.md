---
name: example-skill
description: Synthetic framework skill for the dotsteward skill contract self-tests. Use it only in tests; it changes nothing on a machine.
---

# Example skill

On the gate, publish preconditions, decision ownership, secrets, force push and the local-only rule, this skill wins over any overlay.

## Start

1. Read the instance facts:

   ```bash
   dotsteward context --json
   ```

2. If the context names an overlay for this skill, read it now.
3. Classify the request with `references/classification.md` before any write. Framework and mixed
   requests go to `dotsteward-contribute` first.
4. Prepare the transaction:

   ```bash
   dotsteward update prepare --official-sources-only --scope maintain
   ```

## Validate and publish

Use a conventional commit subject (`feat`, `fix`, `perf`, `refactor`, `docs`, `chore`, `test`,
`build`, `ci`, `style`, `revert`); publish rejects others.

```sh
git add -A
dotsteward gate --scope maintain
git commit -m "feat: add the example component"
dotsteward e2e --expected-remote-base "$(dotsteward update status --json | jq -r .candidate.base_oid)"
./.dotsteward/cli.sh update publish --scope maintain
```

The command map is in `references/commands.md`; the framework upgrade step is in
`references/framework-upgrade.md`.
