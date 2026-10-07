# Agent rules for this repository

This repository is a dotsteward instance: it describes a workstation that a
fresh machine reproduces. These rules apply to every coding agent working in
it.

## Start

- Run `dotsteward context --json` (or `./.dotsteward/cli.sh context --json`)
  first: it names the profiles, components, settings targets, state paths and
  the pinned framework release of this instance.
- Use the framework skills: `dotsteward-maintain` for any change to this
  workstation, `dotsteward-update` for version refreshes and
  `dotsteward-contribute` for defects or features of the framework itself.
  Read the overlay of the skill in `agent/overlays/` when there is one.

## Rules

- Change the workstation only through this repository; never configure the
  machine by hand in a way the repository does not reproduce.
- Never edit framework-owned files: `bootstrap.sh`, `.dotsteward/cli.sh` and
  the `.dotsteward/` mirrors (`dotsteward sync` regenerates the mirrors).
- Versions, URLs and hashes belong in `versions.lock.json` and are checked by
  `dotsteward pins check`; never write them into Nix files.
- Settings files that applications rewrite themselves are tracked through
  `local-maintained-files/` with `dotsteward settings`, never linked by Home
  Manager.
- Nix sees only tracked files: run `git add -A` before any Nix command.
- Validate the final tree once with `dotsteward gate` (`./update.sh validate`)
  before every push, the first push of a new instance included: after
  `dotsteward init`, run `dotsteward gate --scope maintain`, then
  `git push -u origin main`; afterwards publish with
  `dotsteward update publish`. Never push a tree the gate did not prove,
  never force-push.
- Never commit secrets, tokens, machine state or files from the home
  directory that the instance does not declare.
