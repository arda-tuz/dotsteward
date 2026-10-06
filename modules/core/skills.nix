# Skills deployed by Home Manager under the instance skill root: the
# framework skills (D7) and instance-owned home-managed skills.
{
  config,
  lib,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg;
  inherit (dotsteward.lib) contract;
  skills = config.dotsteward.skills;

  frameworkNames = [
    "dotsteward-contribute"
    "dotsteward-maintain"
    "dotsteward-update"
  ];

  present = name: builtins.pathExists (skills.frameworkRoot + "/${name}");
  unknown = lib.filter (name: !lib.elem name frameworkNames) skills.framework;
  missing = lib.filter (name: lib.elem name frameworkNames && !present name) skills.framework;
  collisions = lib.filter (name: skills.homeManaged ? ${name}) skills.framework;
  # A colliding name is reported by an assertion instead of a home.file
  # definition conflict.
  deployed = lib.filter (
    name: lib.elem name frameworkNames && present name && !(skills.homeManaged ? ${name})
  ) skills.framework;

  link = name: source: lib.nameValuePair "${skills.hmRoot}/${name}" { inherit source; };
in
{
  options.dotsteward.skills = {
    hmRoot = lib.mkOption {
      type = contract.types.homeRelativePath;
      default = cfg.skills.hm_root;
      defaultText = lib.literalMD "`[skills] hm_root` of workstation.toml";
      description = "Home-relative directory where Home Manager links skills.";
    };

    framework = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.filter present frameworkNames;
      defaultText = lib.literalMD "the framework skills present in the framework source";
      description = "Framework skills linked from the framework source (${lib.concatStringsSep ", " frameworkNames}).";
    };

    frameworkRoot = lib.mkOption {
      type = lib.types.path;
      # A string, so the links point into the framework source itself
      # ("${dotsteward}/skills/<name>", SPEC 3.3 and the 9.4 invariant)
      # instead of a store copy of each skill.
      default = "${dotsteward.lib.source}/skills";
      defaultText = lib.literalExpression ''"''${dotsteward}/skills"'';
      internal = true;
      description = "The framework's skills directory.";
    };

    homeManaged = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "Instance-owned skills linked by Home Manager: name -> skill directory.";
    };
  };

  config = {
    home.file = lib.listToAttrs (
      map (name: link name (skills.frameworkRoot + "/${name}")) deployed
      ++ lib.mapAttrsToList link skills.homeManaged
    );

    assertions =
      map (name: {
        assertion = false;
        message = "dotsteward: unknown framework skill ${name} (known: ${lib.concatStringsSep ", " frameworkNames})";
      }) unknown
      ++ map (name: {
        assertion = false;
        message = "dotsteward: framework skill ${name} is missing from ${toString skills.frameworkRoot}";
      }) missing
      ++ map (name: {
        assertion = false;
        message = "dotsteward: skill ${name} is both a framework skill and a home-managed skill";
      }) collisions;

    dotsteward.core.backupPaths = [ "~/.agents/skills" ];
  };
}
