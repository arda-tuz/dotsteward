# shellcheck shell=bash
# The Nix system and the platform of the machine a fixture describes, for fixtures that run
# natively on every system of nix/outputs.nix: the platform the CLI will see, the forced
# DOTSTEWARD_PLATFORM first, as current_platform of cli/lib/lib.sh reads it. Not a test file.
#
#   fixture_system     x86_64-linux or aarch64-darwin
#   fixture_platform   linux or darwin
# shellcheck disable=SC2034 # read by the helpers that source this file
case ${DOTSTEWARD_PLATFORM:-$(uname -s)} in
  darwin | Darwin) fixture_system=aarch64-darwin fixture_platform=darwin ;;
  *) fixture_system=x86_64-linux fixture_platform=linux ;;
esac
