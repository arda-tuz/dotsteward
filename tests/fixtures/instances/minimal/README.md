# Minimal instance fixture

The smallest valid dotsteward instance: `workstation.toml` with the required
keys only, a lock with the framework sections, the agent rules file and an
empty settings buffer. There is no `flake.nix`: tests call `lib.mkInstance`
with constructed inputs, and no `.dotsteward/` mirrors: they contain values of
the framework under test, so tests render them into a temporary copy.
