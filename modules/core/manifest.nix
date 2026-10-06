# The manifest (3.7, schema_version 1): the contract values of core and the
# enabled components, as JSON-ready data. It never depends on the profile
# (D20): components are listed when enabled, with their profiles and the mode
# of each profile they are active in, and consumers scope by those. The
# generation ships it as share/dotsteward/manifest.json (package
# dotsteward-manifest); mkInstance adds instance-level values (pinned
# versions, framework revision) through dotsteward.manifestExtra, merged
# recursively.
#
# Top-level keys: schema_version, system, platform, framework, config,
# components, settings_targets, reload_hooks, probes, checks, hooks,
# backup_paths, snapshots, prerequisites, managed_links,
# force_linked_restore, adopt_paths, preflight_detectors, skill_layout,
# agent_rules, update_allowlist, pins, skills, files, login_shell. Entries
# contributed by a component carry its name in "component" ("core" for
# core's own); store paths (hook scripts, agent rules, files) are strings.
{
  config,
  lib,
  pkgs,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg system;
  helpers = import ./helpers.nix { inherit lib; };
  ds = config.dotsteward;

  enabled = helpers.enabled cfg ds.components;

  # Every entry of a component list, tagged with the component.
  tagged =
    select:
    lib.concatMap (
      { name, component }: map (entry: { component = name; } // entry) (select component)
    ) enabled;

  # A union in first-seen order.
  union = lib.foldl' (acc: item: if lib.elem item acc then acc else acc ++ [ item ]) [ ];

  # A set of named records of every component; a name used twice is an error.
  named =
    what: select: render:
    lib.foldl'
      (
        acc: entry:
        if acc ? ${entry.key} then
          throw "dotsteward: ${what} ${entry.key} is declared by components ${acc.${entry.key}.component} and ${entry.component}"
        else
          acc // { ${entry.key} = entry; }
      )
      { }
      (
        lib.concatMap (
          { name, component }:
          lib.mapAttrsToList (
            key: value:
            {
              inherit key;
              component = name;
            }
            // render value
          ) (select component)
        ) enabled
      );
  withoutKey = lib.mapAttrs (_: entry: removeAttrs entry [ "key" ]);

  hook = spec: {
    inherit (spec) name phase profiles;
    script = "${spec.script}";
  };

  hookLists = {
    pre_activate = "preActivate";
    system_install = "systemInstall";
    post_install = "postInstall";
    forbid = "forbid";
    agents_install = "agentsInstall";
    agents_migrate = "agentsMigrate";
    agents_post = "agentsPost";
    desktop_apply = "desktopApply";
  };

  modes =
    component:
    lib.listToAttrs (
      map (profile: lib.nameValuePair profile cfg.profiles.${profile}.mode) (
        lib.filter (
          profile: component.profiles == null || lib.elem profile component.profiles
        ) cfg.profiles.names
      )
    );

  install =
    component:
    if component.method == "nix" then
      { packages = map lib.getName component.install.nix.packages; }
    else
      component.install.${component.method};

  manifest = {
    schema_version = 1;
    inherit system;
    platform = dotsteward.lib.platform.platformOf system;
    framework.version = dotsteward.lib.version;
    config = cfg;

    components = map (
      { name, component }:
      {
        inherit name;
        source = cfg.components.${name}.source or "instance";
        inherit (component)
          method
          profiles
          platforms
          options
          ;
        modes = modes component;
        supported_methods = component.supportedMethods;
        install = install component;
      }
    ) enabled;

    settings_targets = helpers.settingsTargets system dotsteward.lib.platform enabled;
    reload_hooks = helpers.reloadHooks enabled;

    probes = tagged (component: component.probes);

    checks = {
      commands =
        map (command: {
          component = "core";
          inherit command;
        }) ds.core.commands
        ++ tagged (component: map (command: { inherit command; }) component.checks.commands);
      e2e = tagged (component: map hook component.checks.e2e);
      agents = tagged (component: map hook component.checks.agents);
      floors = tagged (component: component.checks.floors);
    };

    hooks = lib.mapAttrs (_: list: tagged (component: map hook component.hooks.${list})) hookLists;

    backup_paths = union (
      ds.core.backupPaths ++ lib.concatMap ({ component, ... }: component.bootstrap.backupPaths) enabled
    );
    snapshots = tagged (
      component:
      map (snapshot: {
        inherit (snapshot) name argv;
        require_command = snapshot.requireCommand;
      }) component.bootstrap.snapshots
    );
    prerequisites.apt = union (
      lib.concatMap ({ component, ... }: component.bootstrap.prerequisites.apt) enabled
    );

    managed_links = ds.managedLinks;
    force_linked_restore = tagged (component: component.rollback.forceLinkedRestore);
    adopt_paths = union (lib.concatMap ({ component, ... }: component.rebuild.adoptPaths) enabled);

    preflight_detectors = withoutKey (
      named "preflight detector" (component: component.preflight.detectors) (detector: {
        inherit (detector) argv;
        match_line = detector.matchLine;
      })
    );

    skill_layout = {
      legacy_roots = union (
        lib.concatMap ({ component, ... }: component.skillLayout.legacyRoots) enabled
      );
      link_roots = withoutKey (
        named "skill link root" (component: component.skillLayout.linkRoots) (root: {
          target_prefix = root.targetPrefix;
        })
      );
      excluded_subtrees = union (
        lib.concatMap ({ component, ... }: component.skillLayout.excludedSubtrees) enabled
      );
    };

    agent_rules = {
      source = ds.agentRules.storePath;
      targets = tagged (component: component.agentRulesTargets);
    };

    update_allowlist = union (lib.concatMap ({ component, ... }: component.gate.updatePaths) enabled);

    pins = {
      rules = tagged (component: component.pins.rules);
      latest = tagged (component: component.pins.latest);
      resolved_versions = lib.foldl' (
        acc:
        { name, component }:
        let
          duplicates = lib.filter (key: acc ? ${key}) (lib.attrNames component.pins.resolvedVersions);
        in
        if duplicates == [ ] then
          acc // component.pins.resolvedVersions
        else
          throw "dotsteward: resolved version ${lib.head duplicates} is declared twice (again by component ${name})"
      ) { } enabled;
      flake_inputs = union (lib.concatMap ({ component, ... }: component.pins.flakeInputs) enabled);
    };

    skills = {
      hm_root = ds.skills.hmRoot;
      framework = ds.skills.framework;
      home_managed = lib.attrNames ds.skills.homeManaged;
    };

    files = lib.mapAttrs (_: file: {
      source = "${file.finalSource}";
      inherit (file) target mode policy;
    }) ds.files;

    login_shell = ds.loginShell.path;
  };
in
{
  options.dotsteward = {
    manifest = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = lib.recursiveUpdate manifest ds.manifestExtra;
      defaultText = lib.literalMD "the contract values of core and the enabled components";
      readOnly = true;
      description = "The manifest (3.7): contract values for the CLI, never dependent on the profile.";
    };

    manifestExtra = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      internal = true;
      description = "Top-level manifest entries added by mkInstance (pinned_versions, framework revision).";
    };

    manifestPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pkgs.writeTextFile {
        name = "dotsteward-manifest";
        destination = "/share/dotsteward/manifest.json";
        text = builtins.toJSON ds.manifest;
      };
      defaultText = lib.literalMD "share/dotsteward/manifest.json with the manifest";
      description = "The package that ships the manifest in the generation.";
    };
  };

  config.home.packages = [ ds.manifestPackage ];
}
