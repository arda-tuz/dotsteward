# Platform facts of the supported systems and per-platform value selection.
#
#   systems                 supported Nix systems, primary first
#   platforms               "linux" and "darwin"
#   forSystem SYSTEM        { system, platform, arch, unameArch, isLinux, isDarwin }
#   platformOf SYSTEM       "linux" or "darwin"
#   selectPath SYSTEM VALUE a string, or the SYSTEM's entry of a
#                           { linux, darwin } table (component settings paths)
#   checkHome CFG SYSTEM    home of the check identity (identity.home on
#                           Linux, identity.darwin_home on darwin)
#   expandHome HOME PATH    "~" and "~/..." expanded with HOME; any other
#                           string unchanged
{ lib, ... }:
let
  inherit (builtins) attrNames toJSON;

  facts = {
    x86_64-linux = {
      platform = "linux";
      arch = "x86_64";
      # `uname -m`, as compared with platform.linux.fast_path.architecture.
      unameArch = "x86_64";
    };
    aarch64-darwin = {
      platform = "darwin";
      arch = "aarch64";
      unameArch = "arm64";
    };
  };

  systems = [
    "x86_64-linux"
    "aarch64-darwin"
  ];

  platforms = [
    "linux"
    "darwin"
  ];

  forSystem =
    system:
    if facts ? ${system} then
      facts.${system}
      // {
        inherit system;
        isLinux = facts.${system}.platform == "linux";
        isDarwin = facts.${system}.platform == "darwin";
      }
    else
      throw "dotsteward: unsupported system ${system} (supported: ${lib.concatStringsSep ", " systems})";

  platformOf = system: (forSystem system).platform;

  describe =
    value:
    if builtins.isInt value then
      "an integer"
    else if builtins.isList value then
      "a list"
    else
      "a ${builtins.typeOf value}";
in
{
  inherit
    systems
    platforms
    forSystem
    platformOf
    ;

  selectPath =
    system: value:
    let
      platform = platformOf system;
    in
    if builtins.isString value then
      value
    else if builtins.isAttrs value then
      let
        unknown = lib.subtractLists platforms (attrNames value);
      in
      if unknown != [ ] then
        throw "dotsteward: per-platform value has unknown keys: ${lib.concatStringsSep ", " unknown} (expected linux, darwin)"
      else if value ? ${platform} then
        value.${platform}
      else
        throw "dotsteward: per-platform value ${toJSON value} has no ${platform} entry"
    else
      throw "dotsteward: expected a string or a { linux, darwin } table, got ${describe value}";

  checkHome =
    cfg: system: if (forSystem system).isDarwin then cfg.identity.darwin_home else cfg.identity.home;

  expandHome =
    home: path:
    if path == "~" then
      home
    else if lib.hasPrefix "~/" path then
      home + lib.removePrefix "~" path
    else
      path;
}
