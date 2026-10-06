{ pkgs, ... }:
{
  # text-guard: the exact version policy of example_policy.exact_versions.
  assertions = [
    {
      assertion = pkgs.example-lint.version == "0.9.0";
      message = "example-lint must stay at its exact version";
    }
  ];
}
