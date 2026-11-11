# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# modules/core observer: on Linux the generation has a systemd user path unit on the dpkg
# status file that starts `dotsteward observe` for the instance checkout whenever dpkg
# writes it, so an apt run of the owner outside dotsteward is noticed. The service also
# runs at login: the user manager watches nothing while nobody is logged in. Waiting with
# a pending mark (3) and a record that waits for the network (6) are no failures of the
# service. macOS has no dpkg and no systemd: no units there. dotsteward.observer.enable =
# false leaves them out.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

linux='{ config = "workstation"; modules = componentModules; }'
darwin='{ config = "workstation"; system = "aarch64-darwin"; homeDirectory = "/Users/alice"; modules = componentModules; }'
off='{ config = "workstation"; modules = componentModules ++ [ { dotsteward.observer.enable = false; } ]; }'

assert_core_eq 'true' "(homeOf $linux).dotsteward.observer.enable"
assert_core_eq '{"Unit":"dotsteward-observe.service","PathChanged":"/var/lib/dpkg/status"}' \
  "(homeOf $linux).systemd.user.paths.dotsteward-observe.Path"
assert_core_eq '["default.target"]' "(homeOf $linux).systemd.user.paths.dotsteward-observe.Install.WantedBy"
assert_core_eq '["default.target"]' "(homeOf $linux).systemd.user.services.dotsteward-observe.Install.WantedBy"
assert_core_eq '"exec"' "(homeOf $linux).systemd.user.services.dotsteward-observe.Service.Type"
assert_core_eq '"3 6"' "(homeOf $linux).systemd.user.services.dotsteward-observe.Service.SuccessExitStatus"
# An apt run writes the status file many times a second: no start limit may stop the path unit.
assert_core_eq '0' "(homeOf $linux).systemd.user.services.dotsteward-observe.Unit.StartLimitIntervalSec"
assert_core_eq 'true' \
  "(homeOf $linux).systemd.user.services.dotsteward-observe.Service.ExecStart == [ \"\${(homeOf $linux).dotsteward.observer.script}\" ]"
# Home Manager writes both units and their links into default.target.wants into the
# generation, and they are managed links of core: E2E checks that they resolve, rollback
# removes them.
assert_core_eq '[true,true,true,true]' \
  "map (name: builtins.hasAttr name (homeOf $linux).xdg.configFile) [ \"systemd/user/dotsteward-observe.path\" \"systemd/user/dotsteward-observe.service\" \"systemd/user/default.target.wants/dotsteward-observe.path\" \"systemd/user/default.target.wants/dotsteward-observe.service\" ]"
assert_core_eq '["~/.config/systemd/user/dotsteward-observe.path","~/.config/systemd/user/dotsteward-observe.service","~/.config/systemd/user/default.target.wants/dotsteward-observe.path","~/.config/systemd/user/default.target.wants/dotsteward-observe.service"]' \
  "lib.filter (lib.hasInfix \"systemd\") (homeOf $linux).dotsteward.manifest.managed_links"

# The service runs the CLI of the generation for the instance checkout, with the commands
# of the profile first on PATH.
script=$(core_raw "(homeOf $linux).dotsteward.observer.script.text")
cli=$(core_raw "\"\${(homeOf $linux).dotsteward.cli.package}/bin/dotsteward\"")
assert_contains "$script" "exec $cli --instance \"/home/alice/workstation\" observe"
assert_contains "$(core_raw "builtins.concatStringsSep \" \" (homeOf $linux).systemd.user.services.dotsteward-observe.Service.Environment")" \
  "PATH=/home/alice/.nix-profile/bin:"

# macOS: no dpkg, no systemd, no units.
assert_core_eq 'false' "(homeOf $darwin).dotsteward.observer.enable"
assert_core_eq '{}' "(homeOf $darwin).systemd.user.paths"
assert_core_eq '{}' "(homeOf $darwin).systemd.user.services"
assert_core_eq '[]' "lib.filter (lib.hasInfix \"systemd\") (homeOf $darwin).dotsteward.manifest.managed_links"

# Switched off.
assert_core_eq '{}' "(homeOf $off).systemd.user.paths"
assert_core_eq '{}' "(homeOf $off).systemd.user.services"
assert_core_eq '[]' "lib.filter (lib.hasInfix \"systemd\") (homeOf $off).dotsteward.manifest.managed_links"
