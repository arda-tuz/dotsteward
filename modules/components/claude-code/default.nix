# claude-code: Claude Code, the coding agent CLI, on Linux and darwin.
#
# Methods (README.md):
#   official-binary (default on both platforms)  the vendor's native build,
#     one executable per release platform, downloaded from the official
#     release bucket with the size and SHA-256 of the instance lock
#     (agent_tools.claude-code.<release platform>) and installed as a regular
#     file at ~/.local/bin/claude. policy = "at-least": a newer build, such
#     as the vendor's native launcher (a symlink into
#     ~/.local/share/claude/versions/), is kept and never downgraded.
#   deb (Linux)  the vendor's DEB from the official APT repository, pinned
#     at desktop_packages.claude-code (a floor; system level, so fresh-mode
#     profiles only).
#   external  claude is installed by something else; only its presence is
#     checked.
#
# The pins (download-pin rules and latest adapters) follow the method of
# each platform in nix.systems, and every system declares the same set,
# since one lock serves all of them: the official-binary pin of the release
# platform of every system whose platform uses official-binary, and the deb
# pin when Linux uses deb. An instance lock needs the entries of its
# methods only. Settings targets, backups, the agent rules link and the
# skill link root do not depend on the method. Nothing joins home.packages:
# every method installs outside Home Manager.
#
# options (the [components.claude-code] options table of workstation.toml):
#   [[components.claude-code.options.plugins]]   # one table per plugin
#   spec = "NAME@MARKETPLACE"
#   marketplace = "OWNER/REPO"                   # optional
#   minimumAt = "<versions.lock.json path>"      # optional
#   requiredFiles = ["<relative path>", ...]     # optional
#   trackAt = "<versions.lock.json path>"        # optional, with watched
#   watched = ["<path pattern>", ...]
# A non-empty list adds the agentsPost hook plugins.sh, which adds missing
# marketplaces and installs or enables missing plugins at user scope (agents
# install) and verifies every listed one (both modes). Each trackAt entry
# (source and observed_marketplace_revision) adds a git-compare review row
# of the marketplace for its watched paths, with every method. Invalid
# options fail the evaluation with every problem listed.
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
  inherit (dotsteward) cfg system;
  inherit (dotsteward.lib.platform) platformOf;

  name = "claude-code";
  component = config.dotsteward.components.${name};
  defaultMethod = "official-binary";
  platform = platformOf system;

  # The method of a platform of nix.systems: the resolved method of this
  # system's platform, the configured one (or the default) of the others.
  methodOn =
    platformName:
    if platformName == platform then
      component.method
    else
      let
        configured =
          if cfg.components ? ${name} then dotsteward.lib.config.methodFor cfg name platformName else null;
      in
      if configured == null then defaultMethod else configured;

  # Release platforms of the native builds, per Nix system.
  releasePlatforms = {
    x86_64-linux = "linux-x64";
    aarch64-darwin = "darwin-arm64";
  };
  releasePlatformOf =
    system':
    releasePlatforms.${system'}
      or (throw "dotsteward: component claude-code has no native build for ${system'} (supported: ${lib.concatStringsSep ", " (lib.attrNames releasePlatforms)})");
  # The release platforms whose system uses official-binary.
  officialReleasePlatforms = map releasePlatformOf (
    lib.filter (system': methodOn (platformOf system') == "official-binary") cfg.nix.systems
  );
  debOnLinux = lib.elem "linux" (map platformOf cfg.nix.systems) && methodOn "linux" == "deb";

  releases = "https://downloads.claude.ai/claude-code-releases";
  aptBase = "https://downloads.claude.ai/claude-code/apt/stable";

  releasePin = platform: "agent_tools.${name}.${platform}";
  debPin = "desktop_packages.${name}";

  officialBinaryPins = {
    rules = map (platform: {
      kind = "download-pin";
      at = releasePin platform;
      url_contains = "/{.version}/${platform}/claude";
    }) officialReleasePlatforms;
    latest = map (platform: {
      id = releasePin platform;
      adapter = "official-manifest";
      at = releasePin platform;
      version_url = "${releases}/stable";
      manifest_url = "${releases}/{version}/manifest.json";
      version_field = "version";
      sha256_field = "platforms.${platform}.checksum";
      size_field = "platforms.${platform}.size";
      url_template = "${releases}/{version}/${platform}/claude";
    }) officialReleasePlatforms;
  };

  debPins = {
    rules = [
      {
        kind = "download-pin";
        at = debPin;
        version_field = "minimum_version";
        url_contains = "/claude-code_{.minimum_version}_amd64.deb";
      }
    ];
    latest = [
      {
        id = debPin;
        adapter = "apt-index";
        at = debPin;
        base = aptBase;
        package = "claude-code";
        dist = "stable";
      }
    ];
  };

  # --- options ------------------------------------------------------------------

  componentOptions = component.options;
  plugins = componentOptions.plugins or [ ];
  pluginList = if isList plugins then plugins else [ ];

  knownOptions = [ "plugins" ];
  knownPluginKeys = [
    "spec"
    "marketplace"
    "minimumAt"
    "requiredFiles"
    "trackAt"
    "watched"
  ];

  specPattern = "[A-Za-z0-9._-]+@[A-Za-z0-9._-]+";
  repoPattern = "[A-Za-z0-9._-]+/[A-Za-z0-9._-]+";
  githubUrlPattern = "https://github[.]com/${repoPattern}";
  lockPathPattern = "[A-Za-z0-9_][A-Za-z0-9_+-]*([.][A-Za-z0-9_][A-Za-z0-9_+-]*)*";
  isLockPath = value: isString value && match lockPathPattern value != null;
  # A path inside the plugin directory: relative, no empty, . or .. segment.
  isPluginPath =
    value:
    let
      segments = lib.splitString "/" value;
    in
    isString value
    && match "[A-Za-z0-9._/+-]+" value != null
    && !lib.any (
      segment:
      elem segment [
        ""
        "."
        ".."
      ]
    ) segments;
  isPatternList =
    value: isList value && value != [ ] && lib.all (item: isString item && item != "") value;

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
      marketplaceProblems = lib.optional (
        plugin ? marketplace
        && !(isString plugin.marketplace && match repoPattern plugin.marketplace != null)
      ) "${at}.marketplace must be a GitHub repository OWNER/REPO, got ${toJSON plugin.marketplace}";
      minimumProblems = lib.optionals (plugin ? minimumAt) (
        let
          path = plugin.minimumAt;
          found = lockAt path;
        in
        if !isLockPath path then
          [ "${at}.minimumAt must be a versions.lock.json path, got ${toJSON path}" ]
        else if found == null then
          [ "${at}.minimumAt: versions.lock.json lacks ${path}" ]
        else
          lib.optional (!isVersionValue found.value)
            "${at}.minimumAt: versions.lock.json ${path} is not a version (a string, or an entry with minimum_version or version)"
      );
      fileProblems = lib.optionals (plugin ? requiredFiles) (
        let
          files = plugin.requiredFiles;
        in
        if !isList files then
          [ "${at}.requiredFiles must be a list of relative paths" ]
        else
          lib.concatLists (
            lib.imap0 (
              position: file:
              lib.optional (!isPluginPath file)
                "${at}.requiredFiles[${toString position}] must be a relative path inside the plugin, got ${toJSON file}"
            ) files
          )
      );
      trackProblems = lib.optionals (plugin ? trackAt) (
        let
          path = plugin.trackAt;
          found = lockAt path;
          entry = found.value;
          source = entry.source or null;
          revision = entry.observed_marketplace_revision or null;
        in
        if !isLockPath path then
          [ "${at}.trackAt must be a versions.lock.json path, got ${toJSON path}" ]
        else if found == null then
          [ "${at}.trackAt: versions.lock.json lacks ${path}" ]
        else if !isAttrs entry then
          [
            "${at}.trackAt: versions.lock.json ${path} must be an entry with source and observed_marketplace_revision"
          ]
        else
          lib.optional (!(isString source && match githubUrlPattern source != null))
            "${at}.trackAt: versions.lock.json ${path}.source must be a GitHub repository URL https://github.com/OWNER/REPO"
          ++
            lib.optional (!(isString revision && match "[0-9a-f]{40}" revision != null))
              "${at}.trackAt: versions.lock.json ${path}.observed_marketplace_revision must be a 40-digit commit"
      );
      watchedProblems =
        if plugin ? watched then
          lib.optional (!isPatternList plugin.watched) "${at}.watched must be a list of path patterns"
          ++ lib.optional (!(plugin ? trackAt)) "${at}.watched needs trackAt"
        else
          lib.optional (plugin ? trackAt) "${at}.trackAt needs watched, a non-empty list of path patterns";
    in
    if !isAttrs plugin then
      [ "${at} must be a table" ]
    else
      lib.optional (!validSpec) "${at}.spec must look like NAME@MARKETPLACE, got ${toJSON spec}"
      ++ lib.optional duplicate "${at}.spec ${spec} is listed twice"
      ++ minimumProblems
      ++ marketplaceProblems
      ++ fileProblems
      ++ map (key: "${at} has unknown key ${key} (known: ${lib.concatStringsSep ", " knownPluginKeys})") (
        filter (key: !elem key knownPluginKeys) (attrNames plugin)
      )
      ++ trackProblems
      ++ watchedProblems;

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

  # A review row per tracked plugin: the marketplace changed a watched path
  # since the observed revision. Only valid entries; invalid ones fail the
  # evaluation through the assertions.
  trackedPlugins = filter (
    plugin:
    isAttrs plugin
    && plugin ? trackAt
    && isLockPath plugin.trackAt
    && isPatternList (plugin.watched or null)
  ) pluginList;
  pluginLatest = map (plugin: {
    id = plugin.trackAt;
    adapter = "git-compare";
    at = plugin.trackAt;
    repo_at = ".source";
    revision_at = ".observed_marketplace_revision";
    inherit (plugin) watched;
  }) trackedPlugins;

  # The same on every system of the instance.
  instancePins = {
    rules = officialBinaryPins.rules ++ lib.optionals debOnLinux debPins.rules;
    latest = officialBinaryPins.latest ++ lib.optionals debOnLinux debPins.latest ++ pluginLatest;
  };
in
{
  dotsteward.components.${name} = {
    method = lib.mkDefault defaultMethod;
    supportedMethods = {
      linux = [
        "official-binary"
        "deb"
        "external"
      ];
      darwin = [
        "official-binary"
        "external"
      ];
    };

    install = {
      official-binary = {
        pin = releasePin (releasePlatformOf system);
        # The release object of each platform is the executable itself (no
        # archive), named claude.
        asset = {
          linux = "linux-x64/claude";
          darwin = "darwin-arm64/claude";
        };
        member = "claude";
        dest = "~/.local/bin/claude";
        versionArgv = [ "--version" ];
        # The native build prints "<version> (Claude Code)".
        versionRegex = "^([0-9]+[.][0-9]+[.][0-9]+) [(]Claude Code[)]";
        policy = "at-least";
        verify = "sha256";
      };
      deb = {
        pin = debPin;
        packageNames = [ "claude-code" ];
        architecture = "amd64";
        verifyAfterInstall = true;
      };
      external = {
        command = "claude";
        versionArgv = [ "--version" ];
      };
    };

    pins = { inherit (instancePins) rules latest; };

    # settings.json holds the user's settings (created when the buffer
    # tracks an entry); ~/.claude.json is the application's own state
    # (sign-in, install method, caches), edited in place, never created and
    # never backed up.
    settingsTargets = {
      claude-settings = {
        path = "~/.claude/settings.json";
        format = "json";
        createIfMissing = true;
        createMode = "0644";
      };
      claude-global = {
        path = "~/.claude.json";
        format = "json";
        createIfMissing = false;
        backup = false;
      };
    };

    bootstrap.backupPaths = [
      "~/.claude/CLAUDE.md"
      "~/.claude/settings.json"
      "~/.claude/skills"
    ];

    rollback.managedLinks = [ "~/.claude/CLAUDE.md" ];

    skillLayout.linkRoots."~/.claude/skills".targetPrefix = "../../.agents/skills/";

    agentRulesTargets = [ { path = ".claude/CLAUDE.md"; } ];

    # The hook is read in place from the framework source, so the manifest
    # mirror names it <dotsteward>/modules/components/claude-code/plugins.sh.
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
