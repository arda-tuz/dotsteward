# A catalog component that installs one vendor DEB published as a GitHub
# release asset (not a module; catalog components import it). The vendor
# runs no APT repository, so the deb method's local APT bridge serves the
# newest release and the package updates only with plain
# `apt update && apt upgrade`; there is no unattended upgrade.
#
#   import ../../core/github-release-deb.nix { inherit lib; } {
#     name = "example-app";            # component, DEB package and command
#     repository = "example/example-app";
#     docs = ./README.md;
#   }
#
# The conventions every such component follows:
#   package       the DEB package is called like the component, amd64 only
#   asset         <name>-{version}-linux-x86_64.deb of release v<version>,
#                 with the release's SHA256SUMS.txt
#   pin           desktop_packages.<name> of versions.lock.json:
#                 { minimum_version, url, size, sha256 }, the url being the
#                 asset of release v<minimum_version>
#   commands      <name> (the application) and <name>-cli (its command line)
#   E2E           github-release-deb-e2e.sh on every profile: the package is
#                 at least the floor, ships a desktop entry, its CLI answers
#                 and APT takes it from the local APT bridge
#   latest        the github-release adapter over the repository's newest
#                 release (tags v<version>)
# Fresh profiles install it in the system-install phase; an adopted machine
# takes it in with `dotsteward install --profile <profile> --component <name>`.
{ lib }:
{
  name,
  repository,
  docs,
}:
let
  pin = "desktop_packages.${name}";
  asset = "${name}-{version}-linux-x86_64.deb";
  releases = "https://github.com/${repository}/releases/download";
in
{
  dotsteward.components.${name} = {
    platforms = [ "linux" ];
    method = lib.mkDefault "deb";
    supportedMethods.linux = [ "deb" ];

    install.deb = {
      inherit pin;
      packageNames = [ name ];
      architecture = "amd64";
      githubRelease = {
        inherit repository;
        assets.amd64 = asset;
      };
    };

    checks = {
      commands = [
        name
        "${name}-cli"
      ];
      # It only reads, so it runs in parallel with the hooks next to it.
      e2e = [
        {
          name = "package";
          script = ./github-release-deb-e2e.sh;
          phase = "main";
          profiles = null;
          parallel = true;
        }
      ];
    };

    pins = {
      rules = [
        {
          kind = "download-pin";
          at = pin;
          version_field = "minimum_version";
          url_contains = "${releases}/v{.minimum_version}/${name}-{.minimum_version}-linux-x86_64.deb";
        }
      ];
      latest = [
        {
          id = pin;
          adapter = "github-release";
          repo = repository;
          tag_prefix = "v";
          at = pin;
          inherit asset;
        }
      ];
    };

    inherit docs;
  };
}
