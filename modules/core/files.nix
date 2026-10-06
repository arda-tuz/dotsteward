# Files installed as regular files (not Home Manager links) by one activation
# entry, dotstewardFiles, after writeBoundary. Substitutions are applied at
# build time; the manifest exports each file's installed bytes (finalSource),
# target, mode and policy, so E2E verifies the same file (R7).
{
  config,
  lib,
  pkgs,
  homeDirectory,
  dotsteward,
  ...
}:
let
  inherit (dotsteward.lib) contract platform;
  files = config.dotsteward.files;

  fileModule =
    { name, config, ... }:
    {
      options = {
        source = lib.mkOption {
          type = lib.types.path;
          description = "The file to install.";
        };
        target = lib.mkOption {
          type = contract.types.homePath;
          description = "Destination (~/...).";
        };
        mode = lib.mkOption {
          type = contract.types.fileMode;
          default = "0644";
          description = "Mode of the installed file.";
        };
        policy = lib.mkOption {
          type = lib.types.enum [
            "always"
            "if-missing"
          ];
          default = "always";
          description = "always: install on every activation; if-missing: only when the target does not exist.";
        };
        substitute = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Replacements applied to the source text at build time (from -> to).";
        };
        finalSource = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          default =
            if config.substitute == { } then
              config.source
            else
              pkgs.writeText (lib.strings.sanitizeDerivationName "dotsteward-file-${name}") (
                builtins.replaceStrings (lib.attrNames config.substitute) (lib.attrValues config.substitute) (
                  builtins.readFile config.source
                )
              );
          defaultText = lib.literalMD "the source, or a store file with the substitutions applied";
          description = "The bytes installed: the source, or the source with the substitutions applied.";
        };
      };
    };

  install =
    file:
    let
      target = lib.escapeShellArg (platform.expandHome homeDirectory file.target);
      command = "$DRY_RUN_CMD ${pkgs.coreutils}/bin/install -D -m ${file.mode} ${lib.escapeShellArg "${file.finalSource}"} ${target}";
    in
    if file.policy == "if-missing" then
      ''
        if [[ ! -e ${target} ]]; then
          ${command}
        fi
      ''
    else
      "${command}\n";
in
{
  options.dotsteward.files = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule fileModule);
    default = { };
    description = "Files installed by the dotstewardFiles activation entry, by id.";
  };

  config = lib.mkIf (files != { }) {
    home.activation.dotstewardFiles = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStrings (id: install files.${id}) (lib.attrNames files)
    );
  };
}
