# Skill overlays

The framework skills are identical for every user. An overlay adds this
instance's own guidance to one of them: extra steps, report language and
format, notes about private components. The skill reads its overlay at run
time, right after `dotsteward context --json`; nothing is merged into the
skill itself.

| Skill | Overlay file |
| --- | --- |
| `dotsteward-maintain` | `agent/overlays/dotsteward-maintain.md` |
| `dotsteward-update` | `agent/overlays/dotsteward-update.md` |
| `dotsteward-contribute` | `agent/overlays/dotsteward-contribute.md` |

A file here is used when it exists. To keep an overlay elsewhere, name its
path in `workstation.toml`:

```toml
[skills.overlays]
dotsteward-update = "docs/update-overlay.md"
```

`dotsteward static` fails when a declared overlay is missing and when this
directory holds anything but overlays of framework skills and this README.

An overlay cannot relax the skill's rules: on the gate, publish
preconditions, decision ownership, secrets, force push and the local-only
rule, the skill wins over any overlay.
