# The packages of the opencode-pi component (lib/packages.nix): pi, built
# from versions.lock.json agent_tools.pi (pi-package.nix), published as
# packages.<system>.pi and built by checks.<system>.pi of the instance.
# OpenCode is no package: the official binary is installed at the user
# level by `dotsteward agents install`.
{
  pkgs,
  pins,
  dsLib,
  ...
}:
{
  pi = {
    package = import ./pi-package.nix {
      inherit pkgs;
      pin = field: dsLib.pinAt pins "agent_tools.pi.${field}" "opencode-pi";
    };
    check = true;
  };
}
