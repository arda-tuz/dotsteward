# The framework files of the dotsteward CLI package (nix/packages/dotsteward.nix)
# as a lib.fileset: VERSION, cli/, engines/, skills/manifest.json, privacy/,
# schema/, template/ (which `dotsteward init` copies and `dotsteward static`
# compares instances with) and the component seeds
# modules/components/*/seed.json (which `dotsteward init` merges), by path;
# missing ones are skipped, so new command files need no edit here. The
# checks' source sets (nix/check-sources.nix) take the package's files from
# here too.
{ lib }:
let
  fs = lib.fileset;
  root = ../..;
  componentsDir = root + "/modules/components";
in
fs.unions (
  [
    (root + "/VERSION")
    (root + "/cli")
  ]
  ++ map fs.maybeMissing [
    (root + "/engines")
    (root + "/skills/manifest.json")
    (root + "/privacy")
    (root + "/schema")
    (root + "/template")
  ]
  ++ lib.optional (builtins.pathExists componentsDir) (
    fs.fileFilter (file: file.name == "seed.json") componentsDir
  )
)
