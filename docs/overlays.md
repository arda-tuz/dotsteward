# Overlays

The framework skills are identical for every user, byte for byte. An
**overlay** adds one instance's own guidance to a skill without changing
it: extra steps, the language and format of reports, notes about private
components, limits of a particular machine. See [skills.md](skills.md) for
the skills themselves.

## Where overlays live

| Skill | Default overlay file |
| --- | --- |
| `dotsteward-maintain` | `agent/overlays/dotsteward-maintain.md` |
| `dotsteward-update` | `agent/overlays/dotsteward-update.md` |
| `dotsteward-contribute` | `agent/overlays/dotsteward-contribute.md` |

A default file is used when it exists. To keep an overlay elsewhere in the
instance, name its path:

```toml
[skills.overlays]
dotsteward-update = "docs/update-overlay.md"
```

`dotsteward-init` has no overlay: it runs before an instance exists.

## How a skill reads its overlay

The overlay is read at run time, never merged at build time. The second
step of every run reads `overlays.<skill>` from `dotsteward context --json`
and, when it is not `null`, reads that file before classifying the
request. Because nothing is merged, the deployed skills keep the digests of
`skills/manifest.json`, and a framework upgrade never conflicts with your
overlay.

`dotsteward static` (and therefore the gate) fails when a declared overlay
file is missing, and when `agent/overlays/` holds anything other than
overlays of framework skills and its `README.md`.

## What an overlay may and may not do

An overlay may:

- add steps, for example an extra check for a private component;
- set the language, tone and format of questions and reports;
- describe private components, their sources and their exact checks;
- state limits of the user's machines (memory, disk, parallelism).

An overlay cannot relax a skill. Every framework skill says so in the same
words:

> On the gate, publish preconditions, decision ownership, secrets, force push and the local-only rule, this skill wins over any overlay.

So an overlay cannot skip or weaken the gate, publish without its proof,
decide for the user, put secrets into a repository, force push, or turn a
local-only request into a repository change.

## Example

```markdown
# Update overlay

- Write the final report as a short table: item, old, new, source.
- `example-term` releases need the smoke test in
  `components/example-term/e2e-smoke.sh` before a new major version is
  accepted.
- Keep the gate's default parallelism.
```

Overlays are instance files: personal, private and changed through
`dotsteward-maintain` like anything else in the instance.
