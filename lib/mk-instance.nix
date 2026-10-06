# lib.mkInstance (3.2): the flake outputs of an instance.
#
#   mkInstance {
#     inputs,                     # instance flake inputs: self, nixpkgs,
#                                 # home-manager (and dotsteward)
#     root ? inputs.self,         # git-filtered instance source
#     config ? root + "/workstation.toml",
#     homeModules ? [ ],          # extra Home Manager modules; root +
#                                 # "/home.nix" is appended when present
#     extraPackages ? (ctx: { }), # ctx = { pkgs, pins, inputs, system, lib,
#     extraChecks ? (ctx: { }),   #   packages, dsLib, root, cfg }
#   }
#
# Outputs:
#   lib.mkHome { username, homeDirectory, profile ? profiles.default,
#                system ? nix.systems[0] }
#                                 Home Manager configuration (the generated
#                                 host flake calls it, F5)
#   lib.pinnedVersions, lib.pinnedVersionsFor.<system>
#   homeConfigurations.<identity.username>
#                                 the check profile on the primary system
#   packages.<system>             component packages (lib/packages.nix),
#                                 dotsteward (the CLI built with the instance
#                                 nixpkgs, F8), local-maintained-files (the
#                                 check configuration's alias), extraPackages
#   checks.<system>               home-<profile> per profile; home (the check
#                                 profile); [compat] check_aliases; component
#                                 packages with check = true;
#                                 dotsteward-manifest (every .dotsteward/
#                                 mirror is current); manifest-consistent
#                                 (D20); instance-static ([gate] static
#                                 scripts); instance-contract (framework
#                                 checks over the instance: static
#                                 --sandbox, the offline pins check,
#                                 settings validate against the evaluated
#                                 component targets, passthru.targetsFile,
#                                 and the generic privacy scan); both run
#                                 with ShellCheck of the instance nixpkgs;
#                                 extraChecks
#   dotstewardManifest.<system>   the evaluated manifest (3.7)
#   dotstewardMirrors             exact contents of the .dotsteward/ mirror
#                                 files, written by `dotsteward sync`
#   apps.<system>.default         the instance CLI
#
# Components: every enabled name of [components]; a catalog component is
# modules/components/<name> of the framework, an instance component
# components/<name>/default.nix of the instance (source = "instance", the
# default for names outside the catalog). mkInstance sets each enabled
# component's enable, options, profiles (when configured) and method (when
# [components.<name>] method_by_platform or method configures one for the
# platform); a component declares its default method with lib.mkDefault.
# Guards: the instance inputs follow the framework's nixpkgs and
# home-manager; every [components.<name>] table names a known component; an
# enabled component supports every configured platform and its resolved
# method there (Home Manager assertions).
{
  dotsteward,
  nixpkgs,
  home-manager,
  lib,
  dsLib,
}:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    elem
    filter
    head
    pathExists
    ;

  args = {
    inherit
      dotsteward
      nixpkgs
      home-manager
      lib
      dsLib
      ;
  };
  manifestLib = import ./manifest.nix args;
  packagesLib = import ./packages.nix args;
  pinnedVersionsOf = import ./pinned-versions.nix args;

  inherit (dsLib) platform;

  # The framework source as a string; a path is not copied to the store.
  framework = toString (dotsteward.outPath or dotsteward);

  frameworkFacts = {
    rev = dotsteward.rev or dotsteward.dirtyRev or null;
    narHash = dotsteward.narHash or null;
  };

  frameworkSkillsManifest =
    let
      file = "${framework}/skills/manifest.json";
    in
    if pathExists file then builtins.fromJSON (builtins.readFile file) else null;

  coreModule = ../modules/core;

  requiredInputs = [
    "self"
    "nixpkgs"
    "home-manager"
  ];

  # Framework commands run by checks.<system>.instance-contract, in order.
  # settings validate reads the component targets from TARGETS_FILE, the
  # evaluated values, not from a committed mirror. The privacy scan is the
  # instance scan of static (generic secret rules and [privacy], SPEC 11.2);
  # `scan` would apply the framework policy (home paths, e-mail addresses,
  # non-ASCII text) to personal instance content.
  contractSteps = targetsFile: [
    [
      "static"
      "--sandbox"
    ]
    [
      "pins"
      "check"
    ]
    [
      "settings"
      "--targets-file"
      "${targetsFile}"
      "validate"
    ]
  ];

  # A framework without one of the commands cannot check an instance.
  missingCommands = filter (command: !pathExists "${framework}/cli/commands/${command}.sh") (
    map head (contractSteps "")
  );
in
{
  inputs,
  root ? inputs.self,
  config ? null,
  homeModules ? [ ],
  extraPackages ? (ctx: { }),
  extraChecks ? (ctx: { }),
}:
let
  # A path (tests, nested instances) or a store path string (flake).
  rootValue = if builtins.isAttrs root then root.outPath else root;
  at = relative: rootValue + "/${relative}";
  rootString = toString rootValue;

  configFile = if config == null then at "workstation.toml" else config;
  cfg = dsLib.config.loadWith { } configFile;

  pins =
    let
      file = at cfg.pins.versions_lock;
    in
    if pathExists file then
      builtins.fromJSON (builtins.readFile file)
    else
      throw "dotsteward: ${cfg.pins.versions_lock} does not exist in the instance ([pins] versions_lock)";

  systems = cfg.nix.systems;
  primary = head systems;
  checkProfile = cfg.profiles.check;
  username = cfg.identity.username;

  # --- Guards -----------------------------------------------------------------

  missingInputs = filter (name: !(inputs ? ${name})) requiredInputs;

  followsProblems =
    lib.concatMap
      (
        { name, own }:
        lib.optional (toString inputs.${name}.outPath != toString own.outPath)
          "dotsteward: the framework input has its own ${name}; add inputs.dotsteward.inputs.${name}.follows = \"${name}\" to flake.nix so the instance and the framework share one ${name}"
      )
      [
        {
          name = "nixpkgs";
          own = nixpkgs;
        }
        {
          name = "home-manager";
          own = home-manager;
        }
      ];

  tableNames = filter (name: name != "order") (attrNames cfg.components);

  componentProblems = lib.concatMap (
    name:
    lib.optional
      (cfg.components.${name}.source == "instance" && !pathExists (at "components/${name}/default.nix"))
      "dotsteward: unknown component ${name} in workstation.toml: neither a catalog component nor an instance component (components/${name}/default.nix)"
  ) tableNames;

  # Each output refuses on its own, so the output names never depend on the
  # instance: in a flake the root is inputs.self, the flake result built from
  # these outputs, and a guard around the whole set would need the root to
  # decide the set itself (infinite recursion).
  guarded = builtins.mapAttrs (
    _: output:
    if missingInputs != [ ] then
      throw "dotsteward: mkInstance: inputs lacks ${concatStringsSep ", " missingInputs} (required: ${concatStringsSep ", " requiredInputs})"
    else if followsProblems != [ ] then
      throw (concatStringsSep "\n" followsProblems)
    else if componentProblems != [ ] then
      throw (concatStringsSep "\n" componentProblems)
    else
      output
  );

  # --- Components and packages ------------------------------------------------

  enabled = map (name: {
    inherit name;
    inherit (cfg.components.${name}) source;
    dir =
      if cfg.components.${name}.source == "catalog" then
        dsLib.catalog.${name}
      else
        at "components/${name}";
  }) (filter (name: cfg.components.${name}.enable) cfg.components.order);

  catalogComponents = filter (component: component.source == "catalog") enabled;
  instanceComponents = filter (component: component.source == "instance") enabled;

  pkgsFor = lib.genAttrs systems (
    system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = cfg.nix.allow_unfree;
    }
  );

  contextFor = system: {
    pkgs = pkgsFor.${system};
    inherit
      pins
      inputs
      system
      lib
      dsLib
      cfg
      ;
    root = rootValue;
  };

  fixpoints = lib.genAttrs systems (
    system:
    packagesLib.fixpoint {
      ctx = contextFor system;
      catalog = map (component: { inherit (component) name dir; }) catalogComponents;
      instance = map (component: { inherit (component) name dir; }) instanceComponents;
      base.dotsteward = dsLib.mkCli pkgsFor.${system};
      inherit extraPackages;
    }
  );

  # --- Home Manager -------------------------------------------------------------

  # Values of workstation.toml, mkInstance's assertions and the instance-level
  # manifest entries.
  instanceModule =
    system:
    { config, ... }:
    let
      platformName = platform.platformOf system;
      components = config.dotsteward.components;
      assertionsOf =
        { name, ... }:
        let
          component = components.${name};
          supported = component.supportedMethods.${platformName};
          supportsPlatform = elem platformName component.platforms;
        in
        [
          {
            assertion = supportsPlatform;
            message = "dotsteward: component ${name} does not support ${platformName} (nix.systems contains ${system}; supported: ${concatStringsSep ", " component.platforms})";
          }
          {
            assertion = !supportsPlatform || elem component.method supported;
            message = "dotsteward: component ${name} does not support method ${component.method} on ${platformName} (supported: ${
              if supported == [ ] then "none" else concatStringsSep ", " supported
            })";
          }
        ];
    in
    {
      dotsteward.components = lib.listToAttrs (
        map (
          { name, ... }:
          let
            table = cfg.components.${name};
            method = dsLib.config.methodFor cfg name platformName;
          in
          lib.nameValuePair name (
            {
              enable = true;
              inherit (table) options;
            }
            // lib.optionalAttrs (table.profiles != null) { inherit (table) profiles; }
            // lib.optionalAttrs (method != null) { inherit method; }
          )
        ) enabled
      );

      assertions = lib.concatMap assertionsOf enabled;

      dotsteward.manifestExtra = {
        pinned_versions = pinnedVersionsOf {
          pkgs = pkgsFor.${system};
          inherit cfg components;
        };
        framework = frameworkFacts;
        skills.framework_manifest = frameworkSkillsManifest;
      };
    };

  homeNix = at "home.nix";

  mkHome =
    {
      username,
      homeDirectory,
      profile ? cfg.profiles.default,
      system ? primary,
    }:
    if !elem system systems then
      throw "dotsteward: mkHome: system ${system} is not in nix.systems (${concatStringsSep ", " systems})"
    else
      inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsFor.${system};
        extraSpecialArgs = {
          inherit
            inputs
            pins
            profile
            username
            homeDirectory
            ;
          inherit (fixpoints.${system}) packages;
          dotsteward = {
            inherit cfg system;
            root = rootValue;
            lib = dsLib;
          };
        };
        modules = [
          coreModule
        ]
        ++ map (component: component.dir + "/default.nix") (catalogComponents ++ instanceComponents)
        ++ [ (instanceModule system) ]
        ++ homeModules
        ++ lib.optional (pathExists homeNix) homeNix;
      };

  # The check identity's configuration of every system and profile.
  homes = lib.genAttrs systems (
    system:
    lib.genAttrs cfg.profiles.names (
      profile:
      mkHome {
        inherit username profile system;
        homeDirectory = platform.checkHome cfg system;
      }
    )
  );

  checkConfig = system: homes.${system}.${checkProfile}.config;

  manifests = lib.genAttrs systems (system: (checkConfig system).dotsteward.manifest);

  pinnedVersionsFor = lib.genAttrs systems (
    system:
    pinnedVersionsOf {
      pkgs = pkgsFor.${system};
      inherit cfg;
      inherit ((checkConfig system).dotsteward) components;
    }
  );

  mirrors = manifestLib.mirrors {
    inherit cfg pins manifests;
    root = rootString;
    inherit framework;
  };

  packagesFor = lib.genAttrs systems (
    system:
    let
      alias = (checkConfig system).dotsteward.cli.aliasPackage;
    in
    lib.optionalAttrs (alias != null) { local-maintained-files = alias; }
    // fixpoints.${system}.packages
  );

  # --- Checks -------------------------------------------------------------------

  rootSource = "${rootValue}";

  instanceCheck =
    system: name: extra: script:
    let
      pkgs = pkgsFor.${system};
      cli = fixpoints.${system}.packages.dotsteward;
    in
    pkgs.runCommand name
      (
        {
          # ShellCheck at the instance's version: `dotsteward static` and
          # the instance's static scripts lint with it.
          nativeBuildInputs = cli.toolchain ++ [
            cli
            pkgs.shellcheck
          ];
        }
        // extra
      )
      ''
        cp -R ${rootSource} instance
        chmod -R u+w instance
        cd instance
        export HOME=$TMPDIR/home DOTSTEWARD_INSTANCE=$PWD
        mkdir -p "$HOME"
        ${script}
        touch "$out"
      '';

  staticScripts =
    let
      missing = filter (script: !pathExists (at script)) cfg.gate.static;
    in
    if missing != [ ] then
      throw "dotsteward: [gate] static: ${head missing} does not exist in the instance"
    else
      cfg.gate.static;

  # The component settings targets and reload hooks of every enabled
  # component (the manifest is the same in every profile, D20), in the
  # format of the generation's targets file.
  targetsFileFor =
    system:
    pkgsFor.${system}.writeText "dotsteward-settings-targets.json" (
      builtins.toJSON {
        schema_version = 1;
        targets = manifests.${system}.settings_targets;
        inherit (manifests.${system}) reload_hooks;
      }
    );

  contract =
    system:
    let
      targetsFile = targetsFileFor system;
    in
    if missingCommands != [ ] then
      throw "dotsteward: the framework CLI lacks the command ${head missingCommands} (instance-contract)"
    else
      instanceCheck system "instance-contract" { passthru = { inherit targetsFile; }; } (
        lib.concatMapStrings (step: ''
          echo "[dotsteward] instance contract: dotsteward ${lib.escapeShellArgs step}"
          dotsteward ${lib.escapeShellArgs step}
        '') (contractSteps targetsFile)
      );

  consistency =
    system:
    let
      reference = homes.${system}.${checkProfile}.config.dotsteward.manifest;
      differing = lib.concatMap (
        profile:
        let
          manifest = homes.${system}.${profile}.config.dotsteward.manifest;
          keys = filter (key: (manifest.${key} or null) != (reference.${key} or null)) (
            lib.unique (attrNames manifest ++ attrNames reference)
          );
        in
        lib.optional (keys != [ ])
          "dotsteward: the manifest of profile ${profile} differs from the manifest of profile ${checkProfile} on ${system} (keys: ${concatStringsSep ", " keys}); contract options (dotsteward.*) must not depend on the profile: scope a component with its profiles field instead"
      ) (filter (profile: profile != checkProfile) cfg.profiles.names);
    in
    if differing != [ ] then
      throw (concatStringsSep "\n" differing)
    else
      pkgsFor.${system}.runCommand "manifest-consistent" { } ''
        echo "manifest identical in profiles: ${concatStringsSep " " cfg.profiles.names}"
        touch "$out"
      '';

  mirrorCheck =
    system:
    let
      problems = manifestLib.staleMirrors {
        root = rootValue;
        inherit mirrors;
      };
    in
    if problems != [ ] then
      throw (concatStringsSep "\n" problems)
    else
      pkgsFor.${system}.runCommand "dotsteward-manifest" { } ''
        echo "current mirrors: ${concatStringsSep " " (attrNames mirrors)}"
        touch "$out"
      '';

  checksFor =
    system:
    let
      activation = profile: homes.${system}.${profile}.activationPackage;
      builtin = {
        home = activation checkProfile;
      }
      // lib.listToAttrs (
        map (profile: lib.nameValuePair "home-${profile}" (activation profile)) cfg.profiles.names
      )
      // lib.mapAttrs (_: activation) cfg.compat.check_aliases
      // {
        dotsteward-manifest = mirrorCheck system;
        manifest-consistent = consistency system;
        # The scripts run as `dotsteward static` runs them, with the
        # environment they are documented to get (DOTSTEWARD_INSTANCE_ROOT,
        # DOTSTEWARD_SANDBOX=1 and the fail helper).
        instance-static = instanceCheck system "instance-static" { } (
          lib.optionalString (staticScripts != [ ]) ''
            echo "[dotsteward] instance static: ${lib.concatStringsSep " " staticScripts}"
            dotsteward static --sandbox --only scripts
          ''
        );
        instance-contract = contract system;
      };
      sources = [
        {
          source = "mkInstance";
          checks = builtin;
        }
        {
          source = "a component package";
          checks = fixpoints.${system}.checks;
        }
        {
          source = "extraChecks";
          checks = extraChecks (contextFor system // { packages = packagesFor.${system}; });
        }
      ];
      merged =
        lib.foldl'
          (
            acc:
            { source, checks }:
            lib.foldl' (
              acc: name:
              if acc.sources ? ${name} then
                throw "dotsteward: check ${name} is defined twice (by ${acc.sources.${name}} and by ${source})"
              else
                {
                  sources = acc.sources // {
                    ${name} = source;
                  };
                  checks = acc.checks // {
                    ${name} = checks.${name};
                  };
                }
            ) acc (attrNames checks)
          )
          {
            sources = { };
            checks = { };
          }
          sources;
    in
    merged.checks;
in
guarded {
  lib = {
    inherit mkHome pinnedVersionsFor;
    pinnedVersions = pinnedVersionsFor.${primary};
  };

  homeConfigurations.${username} = homes.${primary}.${checkProfile};

  packages = packagesFor;

  checks = lib.genAttrs systems checksFor;

  dotstewardManifest = manifests;

  dotstewardMirrors = mirrors;

  apps = lib.genAttrs systems (system: {
    default = {
      type = "app";
      program = "${packagesFor.${system}.dotsteward}/bin/dotsteward";
      meta.description = "dotsteward command line interface of this instance";
    };
  });
}
