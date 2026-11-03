# The source sets of the checks (nix/check-sources.nix) cover the tree: every
# check of nix/checks has a set and every set a check, and every file of the
# tree is in the set of a check (a whole-tree check with the files its own
# tests read), in the list of files no check reads or in the list of files
# only the flake evaluation reads. A gap fails the evaluation of this check,
# naming the files. The build writes the number of files of each set.
# tests/host/test-check-sources.sh proves with real Nix that every check
# depends on its set and on no other file.
{
  pkgs,
  lib,
  ...
}:
let
  checkSources = import ../check-sources.nix { inherit lib; };

  checkNames = map (lib.removeSuffix ".nix") (
    lib.attrNames (
      lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (builtins.readDir ./.)
    )
  );
  setNames = lib.attrNames checkSources.report.sources;
  withoutSet = lib.subtractLists setNames checkNames;
  withoutCheck = lib.subtractLists checkNames setNames;
  inherit (checkSources) uncovered;
in
if withoutSet != [ ] then
  throw "check-sources: checks without a source set in nix/check-sources.nix: ${lib.concatStringsSep ", " withoutSet}"
else if withoutCheck != [ ] then
  throw "check-sources: source sets of nix/check-sources.nix without a check: ${lib.concatStringsSep ", " withoutCheck}"
else if uncovered != [ ] then
  throw "check-sources: files in no source set and in no list of nix/check-sources.nix (add them to the set of the check that tests them, or to untested): ${lib.concatStringsSep ", " uncovered}"
else
  pkgs.writeText "dotsteward-check-check-sources" (
    lib.concatMapStrings (
      name: "${name} ${toString (lib.length checkSources.report.sources.${name})}\n"
    ) setNames
  )
