# Skills

dotsteward ships agent skills that drive the CLI for you. A skill decides
what to do; the CLI does it deterministically and reports through exit
codes and JSON. This page describes the framework skills, how they reach a
machine, and the rules every skill follows.

## The skills

| Skill | Distributed through | Job |
| --- | --- | --- |
| `dotsteward-init` | plugin marketplaces and skills installers | Set up a new instance, or install an existing one on a new machine. |
| `dotsteward-maintain` | the pinned framework, deployed by Home Manager | Personal changes: add, remove, replace or reconfigure components; track settings and write local settings back. |
| `dotsteward-update` | the pinned framework, deployed by Home Manager | Refresh every pin to the newest compatible stable release, and upgrade the framework ([update-policy.md](update-policy.md)). |
| `dotsteward-contribute` | the pinned framework, deployed by Home Manager | Change the framework itself, publish it, and upgrade the instance to the result ([contribute.md](contribute.md)). |

`dotsteward-init` lives in `plugins/dotsteward/skills/` and is the only
skill installed from a channel:

```sh
claude plugin marketplace add https://github.com/arda-tuz/dotsteward.git
claude plugin install dotsteward@dotsteward
```

The Codex plugin marketplace and `gh skill install` work the same way (see
[getting-started-ubuntu.md](getting-started-ubuntu.md)). The other three
live in `skills/` and come with the framework release an instance pins, so
their bytes are the same for every user of that release.

## Deployment

Home Manager links the framework skills of the active generation into the
skill root `skills.hm_root` of `workstation.toml` (default
`.agents/skills` in the home directory). `dotsteward agents install`
completes the layout for every agent: link roots, copies of the vendored
instance skills, and the cleanup of dangling links; `dotsteward agents check`
verifies it, and the end-to-end checks compare the deployed framework
skills with `skills/manifest.json`, the digests that
`tools/gen-skills-manifest.sh` generates.

An instance may vendor its own skills under `agent/skills/` (the
`[skills]` table of `workstation.toml`). They are pinned in
`agent/skills.lock.json` with their source revision and digests, refreshed
with `dotsteward pins sync --skill NAME`, and researched by `pins latest`
(adapter `skill-source`). Framework skills never appear in that lock; they
move only with a framework upgrade.

## Structure of a skill

Each framework skill is a directory with:

- `SKILL.md`: frontmatter `name` (equal to the directory) and
  `description` (at most 1024 characters), then the procedure;
- `agents/openai.yaml`: the display name, a short description and a
  default prompt that mentions the skill;
- `LICENSE`: MIT;
- `references/*.md`: detail the procedure reads on demand; every reference
  is linked from `SKILL.md`.

The skill contract tests in `tests/skills/` check all of this, and also
that every `dotsteward` command and option a skill shows in a fenced block
exists.

## First steps of every run

The maintain, update and contribute skills start the same way:

1. `dotsteward context --json` reads the instance facts once: paths,
   identities, profiles, components, settings targets, commit rules and
   overlays.
2. If the instance has an overlay for the skill, the skill reads it now
   ([overlays.md](overlays.md)).
3. The request is classified before anything is written.

Every framework `SKILL.md` contains the precedence sentence:

> On the gate, publish preconditions, decision ownership, secrets, force push and the local-only rule, this skill wins over any overlay.

## Classification

| Class | Definition | Route |
| --- | --- | --- |
| personal | expressible by changing instance files: `workstation.toml`, locks, `home.nix`, `components/`, `agent/`, overlays, the settings buffer, tests, instance docs | `dotsteward-maintain` or `dotsteward-update` |
| framework | changes behaviour or text the framework ships: CLI, engines, gate, catalog components, framework skills, template, framework docs | `dotsteward-contribute` |
| mixed | both | `dotsteward-contribute` first (it ends with an instance upgrade), then `dotsteward-maintain` |

Tie-breakers: a preference only you want that the contract can express is
personal (configuration, overlay or private component); a defect any user
would hit is framework; an application outside the catalog is personal
(a private component), and proposing it for the catalog is a separate,
explicit framework request. Editing installed framework files in place is
never allowed. The rules live in `references/classification.md` of each of
the three skills, with identical bytes.

## Shared rules

- **Local-only requests stay local**: a change wanted only on this machine
  never touches the repository.
- **One gate per final tree**, run once and waited for; publishing requires
  the gate's proof for exactly the committed tree, never a force push.
- **Decisions belong to the user**: settings conflicts, holdbacks, major
  versions and creating a fork are asked, never assumed.
- **No secrets or machine state** in any repository.
