# Framework upgrade

When the `framework` row is `review`, read the notes of every release between the pinned and the
newest tag, move the tag, then validate the combined tree once.

```bash
gh release list --repo "$upstream" --exclude-drafts --exclude-pre-releases
gh release view "$tag" --repo "$upstream"
nix flake update dotsteward
dotsteward gate --scope update
```

A red gate leaves the instance on the old tag.
