# Framework upgrade

## Contents

1. When it runs
2. Read the release notes
3. Move the tag
4. Refresh the template-owned files
5. Research again, then the single gate
6. Red gate: the instance stays on the old tag
7. Report

## When it runs

The framework upgrade step runs when the `framework` row of `$work/latest.json` is `review`: the upstream of the instance's `dotsteward` flake input has a newer stable release than the tag the instance pins. The upstream is never configured separately; it is the original reference of the `dotsteward` node of `flake.lock` (`framework.upstream` in the context, `details.upstream` in the row).

- `manual`: the input is not pinned to a release tag (or is a local path). Report it; do not move it.
- `error`: retry `pins latest` once; if it persists, report it and leave the framework as it is.

Run the step in the clone right after the research of section 1 of `SKILL.md`, before any other edit: a release can change the CLI, the catalog declarations, the lock rules and the gate, and every later step should already see the new release.

## Read the release notes

```bash
row=$(jq -c --arg id framework '.items[] | select($id == .id)' "$work/latest.json")
old=$(jq -r .current <<<"$row")
new=$(jq -r .latest <<<"$row")
upstream=$(jq -r .details.upstream <<<"$row")
repo=${upstream#github:}
repo=${repo#git+}
repo=${repo#ssh://git@github.com/}
repo=${repo#https://github.com/}
repo=${repo%%\?*}
repo=${repo%.git}
timeout 60 gh release list --repo "$repo" --exclude-drafts --exclude-pre-releases --limit 100 --json tagName --jq '.[].tagName' >"$work/framework-tags.txt"
sort -V "$work/framework-tags.txt" | awk -v old="$old" -v new="$new" 'seen { print } $0 == old { seen = 1 } seen && $0 == new { exit }' >"$work/framework-releases.txt"
while IFS= read -r tag; do timeout 60 gh release view "$tag" --repo "$repo"; done <"$work/framework-releases.txt"
```

`repo` is the `OWNER/REPO` of a GitHub upstream (`github:OWNER/REPO`, or a `git+ssh` or `git+https` URL on github.com). An upstream elsewhere has no `gh` releases: list its tags with `timeout 60 git ls-remote --tags --refs <url>` and read the notes on the upstream's release page or as `git log <old>..<new>` in a temporary clone. When the old tag is no longer listed, read every release newer than it by version.

Read every release between the pinned and the newest tag, not only the newest one: release notes name breaking changes and the instance changes a release needs. Show the user the notes that matter (breaking changes, new requirements, migrations) before you continue.

Stop the framework part of this run, keep the old tag and report why when a release needs instance changes outside the update scope (for example new `workstation.toml` keys, component or overlay changes). Those changes and the upgrade then run together as a `dotsteward-maintain` transaction. The rest of this update continues on the old tag.

## Move the tag

Change only the tag of the `dotsteward` input in `flake.nix` (`github:OWNER/REPO/<tag>` or `?ref=refs/tags/<tag>`), from `$old` to `$new`; its `follows` lines stay as they are. Find the line first and edit just that reference:

```bash
git grep -n -F "$old" -- flake.nix
```

Then lock the new release and find its source in the Nix store:

```bash
git add -A
nix flake update dotsteward
jq -r '.nodes[.nodes[.root].inputs.dotsteward].original.ref' flake.lock
src=$(nix flake archive --json --dry-run --no-update-lock-file . | jq -r .inputs.dotsteward.path)
```

The `original.ref` printed must be the new tag (with or without `refs/tags/`). `$src` is the framework source of the new release, read-only; the catalog components' `maintenance.md` files are below `$src/modules/components/`.

## Refresh the template-owned files

`bootstrap.sh` and `.dotsteward/cli.sh` are framework-owned: the static contracts of the gate require them to equal `template/` of the pinned release byte for byte. Copy them from the new release (store files are read-only, so set the mode explicitly):

```bash
install -m 0755 "$src/template/bootstrap.sh" bootstrap.sh
install -m 0755 "$src/template/.dotsteward/cli.sh" .dotsteward/cli.sh
```

The other wrappers (`rebuild.sh`, `rollback.sh`, `update.sh`) belong to the instance; change them only when the release notes ask for it.

## Research again, then the single gate

The launcher now runs the new release's CLI (the key of its cache is the hash of `flake.lock`, so the first call builds it). Regenerate the mirrors, research with the new declarations, and continue with section 2 of `SKILL.md` for the other rows:

```bash
git add -A
./.dotsteward/cli.sh sync
./.dotsteward/cli.sh pins latest --out "$work/latest.json"
```

There is no separate gate for the framework upgrade. The combined tree (framework release and every other update) is validated once, as section 4 of `SKILL.md` describes:

```bash
git add -A
./.dotsteward/cli.sh gate
```

## Red gate: the instance stays on the old tag

Nothing is published before the gate passes, so a red gate leaves the instance on the old tag. Read the failure:

- A failure in an instance file the release notes asked you to change (a lock value, a wrapper): fix it, `git add -A`, run the gate again.
- A failure in the framework itself (its CLI, a catalog component, the template, a framework check) is a framework defect. Never patch framework files or work around them in the instance. Report it and hand it to `dotsteward-contribute`.

To still publish the other updates of this run, return the clone to the old tag and validate again. Edit the `dotsteward` reference in `flake.nix` back to `$old`, then:

```bash
git add -A
nix flake update dotsteward
git checkout HEAD -- bootstrap.sh .dotsteward/cli.sh
git add -A
./.dotsteward/cli.sh sync --nix
./.dotsteward/cli.sh gate
```

Report the framework row as not taken, with the reason.

## Report

For a framework upgrade the report adds: the old and new tag, the upstream, a short summary of every release's notes between them (breaking changes first) and whether the gate passed on the new release.
