{ pins, dotsteward, ... }:
{
  # Reads every hash from the lock; no literal hash here.
  dotsteward.components.example-app.pins.resolvedVersions.example-app =
    dotsteward.lib.pinAt pins "agent_tools.example-app.version" "example-app";
}
