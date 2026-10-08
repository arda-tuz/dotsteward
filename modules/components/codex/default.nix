# The codex catalog component: the Codex CLI, its agent rules
# link, its configuration file as a settings target and its legacy skill
# root; optionally Codex plugins (options.plugins).
#
# Methods, on Linux and darwin alike:
#   official-binary (default)  the official release archive of the platform
#                               (GitHub releases of openai/codex, tags
#                               rust-v<version>), verified by size and
#                               SHA-256 from agent_tools.codex.<platform> of
#                               versions.lock.json, its single member
#                               installed as ~/.local/bin/codex; at-least
#                               keeps a newer binary
#   external                    installed by the user; codex is expected on
#                               PATH
# Sigstore: the Linux release ships a sigstore bundle for the binary inside
# the archive, darwin none; the installer verifies sha256 only (README.md,
# "Verification").
#
# options (the [components.codex] options table of workstation.toml):
#   [[components.codex.options.plugins]]          # one table per plugin
#   spec = "NAME@MARKETPLACE"
#   minimumAt = "<versions.lock.json path>"       # optional
#   requiredSkillDirectories = ["<dir>", ...]     # optional
# A non-empty list adds the agentsPost hook plugins.sh, which installs
# missing plugins (agents install) and verifies every listed one (both
# modes). Invalid options fail the evaluation with every problem listed.
{
  config,
  lib,
  pins,
  dotsteward,
  ...
}:
let
  inherit (builtins)
    attrNames
    elem
    filter
    genList
    isAttrs
    isList
    isString
    length
    match
    toJSON
    ;

  name = "codex";
  inherit (dotsteward) cfg system;
  dsLib = dotsteward.lib;
  component = config.dotsteward.components.${name};

  platform = dsLib.platform.platformOf system;

  # The official releases: one archive per platform holding one member, the
  # binary.
  repo = "openai/codex";
  tagPrefix = "rust-v";
  releases = {
    linux = {
      asset = "codex-x86_64-unknown-linux-musl.tar.gz";
      member = "codex-x86_64-unknown-linux-musl";
    };
    darwin = {
      asset = "codex-aarch64-apple-darwin.tar.gz";
      member = "codex-aarch64-apple-darwin";
    };
  };
  defaultMethod = "official-binary";
  pinOf = platformName: "agent_tools.codex.${platformName}";

  # The platforms of nix.systems whose method is official-binary: each one
  # reads its own release pin, and every system's manifest declares the pin
  # rules of all of them (one lock serves every system).
  methodOn =
    platformName:
    if platformName == platform then
      component.method
    else
      let
        configured =
          if cfg.components ? ${name} then dsLib.config.methodFor cfg name platformName else null;
      in
      if configured == null then defaultMethod else configured;
  pinnedPlatforms = filter (platformName: methodOn platformName == "official-binary") (
    lib.unique (map dsLib.platform.platformOf cfg.nix.systems)
  );

  # --- options ------------------------------------------------------------------

  componentOptions = component.options;
  plugins = componentOptions.plugins or [ ];
  pluginList = if isList plugins then plugins else [ ];

  knownOptions = [ "plugins" ];
  knownPluginKeys = [
    "spec"
    "minimumAt"
    "requiredSkillDirectories"
  ];

  specPattern = "[A-Za-z0-9._-]+@[A-Za-z0-9._-]+";
  lockPathPattern = "[A-Za-z0-9_][A-Za-z0-9_+-]*(\\.[A-Za-z0-9_][A-Za-z0-9_+-]*)*";
  isPlainName =
    value:
    isString value
    && match "[A-Za-z0-9._-]+" value != null
    && !elem value [
      "."
      ".."
    ];

  # The lock value at a dotted path, or null when the path is missing.
  lockAt =
    path:
    let
      segments = lib.splitString "." path;
    in
    if lib.hasAttrByPath segments pins then { value = lib.getAttrFromPath segments pins; } else null;

  # A minimum version: a non-empty string, or an entry with minimum_version
  # or version (as the install methods read pins).
  isVersionValue =
    value:
    let
      nonEmpty = field: isString (value.${field} or null) && value.${field} != "";
    in
    (isString value && value != "")
    || (isAttrs value && (nonEmpty "minimum_version" || nonEmpty "version"));

  pluginProblems =
    index: plugin:
    let
      at = "options.plugins[${toString index}]";
      spec = plugin.spec or null;
      validSpec = isString spec && match specPattern spec != null;
      earlier = lib.take index pluginList;
      duplicate = validSpec && lib.any (other: isAttrs other && (other.spec or null) == spec) earlier;
      minimumProblems = lib.optionals (plugin ? minimumAt) (
        let
          path = plugin.minimumAt;
          found = lockAt path;
        in
        if !(isString path && match lockPathPattern path != null) then
          [ "${at}.minimumAt must be a versions.lock.json path, got ${toJSON path}" ]
        else if found == null then
          [ "${at}.minimumAt: versions.lock.json lacks ${path}" ]
        else
          lib.optional (!isVersionValue found.value)
            "${at}.minimumAt: versions.lock.json ${path} is not a version (a string, or an entry with minimum_version or version)"
      );
      skillProblems = lib.optionals (plugin ? requiredSkillDirectories) (
        let
          directories = plugin.requiredSkillDirectories;
        in
        if !isList directories then
          [ "${at}.requiredSkillDirectories must be a list of directory names" ]
        else
          lib.concatLists (
            lib.imap0 (
              position: directory:
              lib.optional (!isPlainName directory)
                "${at}.requiredSkillDirectories[${toString position}] must be a plain directory name, got ${toJSON directory}"
            ) directories
          )
      );
    in
    if !isAttrs plugin then
      [ "${at} must be a table" ]
    else
      map (key: "${at} has unknown key ${key} (known: ${lib.concatStringsSep ", " knownPluginKeys})") (
        filter (key: !elem key knownPluginKeys) (attrNames plugin)
      )
      ++ lib.optional (!validSpec) "${at}.spec must look like NAME@MARKETPLACE, got ${toJSON spec}"
      ++ lib.optional duplicate "${at}.spec ${spec} is listed twice"
      ++ minimumProblems
      ++ skillProblems;

  optionProblems =
    map (key: "unknown option ${key} (known: ${lib.concatStringsSep ", " knownOptions})") (
      filter (key: !elem key knownOptions) (attrNames componentOptions)
    )
    ++ (
      if !isList plugins then
        [ "options.plugins must be a list of tables" ]
      else
        lib.concatLists (genList (index: pluginProblems index (lib.elemAt plugins index)) (length plugins))
    );
in
{
  dotsteward.components.${name} = {
    method = lib.mkDefault defaultMethod;
    supportedMethods = {
      linux = [
        "official-binary"
        "external"
      ];
      darwin = [
        "official-binary"
        "external"
      ];
    };

    install = {
      official-binary = {
        pin = pinOf platform;
        asset = lib.mapAttrs (_: release: release.asset) releases;
        inherit (releases.${platform}) member;
        dest = "~/.local/bin/codex";
        versionArgv = [ "--version" ];
        versionRegex = "^codex-cli ([0-9]+([.][0-9]+)+(-[0-9A-Za-z.]+)?)";
        policy = "at-least";
        verify = "sha256";
      };
      external = {
        command = "codex";
        versionArgv = [ "--version" ];
      };
    };

    pins = {
      rules = map (platformName: {
        kind = "download-pin";
        name = "release-${platformName}";
        at = pinOf platformName;
        url_contains = "https://github.com/${repo}/releases/download/${tagPrefix}{.version}/${releases.${platformName}.asset}";
      }) pinnedPlatforms;
      latest = map (platformName: {
        id = pinOf platformName;
        adapter = "github-release";
        inherit repo;
        tag_prefix = tagPrefix;
        at = pinOf platformName;
        inherit (releases.${platformName}) asset;
      }) pinnedPlatforms;
    };

    agentRulesTargets = [
      {
        path = ".codex/AGENTS.md";
        force = true;
      }
    ];

    settingsTargets.codex = {
      path = "~/.codex/config.toml";
      format = "toml";
      createIfMissing = true;
      createMode = "0600";
    };

    bootstrap.backupPaths = [
      "~/.codex/AGENTS.md"
      "~/.codex/config.toml"
    ];

    rollback = {
      managedLinks = [ "~/.codex/AGENTS.md" ];
      forceLinkedRestore = [
        {
          path = "~/.codex/AGENTS.md";
          mode = "0664";
        }
      ];
    };

    skillLayout = {
      legacyRoots = [ "~/.codex/skills" ];
      excludedSubtrees = [ ".system" ];
    };

    # The hook is read in place from the framework source, so the manifest
    # mirror names it <dotsteward>/modules/components/codex/plugins.sh.
    hooks.agentsPost = lib.optional (pluginList != [ ]) {
      name = "plugins";
      script = toString ./plugins.sh;
    };

    docs = ./README.md;
  };

  assertions = lib.optionals component.enable (
    map (message: {
      assertion = false;
      message = "dotsteward: component ${name}: ${message}";
    }) optionProblems
  );
}
