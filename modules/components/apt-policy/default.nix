# apt-policy: the system files that bind the other drivers of apt to what `dotsteward
# upgrade` does with the gated classes (method system, Linux only).
#
# /etc/apt/apt.conf.d/52dotsteward-unattended-upgrades keeps unattended-upgrades from
# removing kernels and dependencies on its own: a kernel goes when `dotsteward upgrade`
# says so. The pin file of the gated classes and its dpkg hook are not here: they follow
# what dpkg has, so `dotsteward upgrade` writes them (docs/upgrade.md). The E2E hook
# reads what apt makes of the drop-in; `dotsteward install --check-only` its bytes.
{ lib, ... }:
{
  dotsteward.components.apt-policy = {
    platforms = [ "linux" ];
    method = lib.mkDefault "system";
    supportedMethods.linux = [ "system" ];

    install.system.files = [
      {
        path = "/etc/apt/apt.conf.d/52dotsteward-unattended-upgrades";
        text = builtins.readFile ./52dotsteward-unattended-upgrades;
        mode = "0644";
      }
    ];

    checks.e2e = [
      {
        name = "unattended-upgrades";
        script = ./e2e-unattended.sh;
        phase = "main";
        profiles = null;
        parallel = true;
      }
    ];

    docs = ./README.md;
  };
}
