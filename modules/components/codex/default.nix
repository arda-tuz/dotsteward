# The codex catalog component: the Codex CLI, its agent rules
# link, its configuration file as a settings target and its legacy skill
# root; optionally Codex plugins (options.plugins).
#
# Methods, on Linux and darwin alike:
#   official-binary (default)  the official release archives of the platform
#                               (GitHub releases of openai/codex, tags
#                               rust-v<version>), verified by size and
#                               SHA-256 from versions.lock.json: the member
#                               of agent_tools.codex.<platform> installed as
#                               ~/.local/bin/codex (at-least keeps a newer
#                               binary), and from 0.144.0 on the member of
#                               agent_tools.codex-code-mode-host.<platform>
#                               next to it (README.md, "The helper")
#   external                    installed by the user; codex is expected on
#                               PATH
# Sigstore: the Linux release ships a sigstore bundle for the binary inside
# the archive, darwin none; the installer verifies sha256 only (README.md,
# "Verification").
#
# options (the [components.codex] options table of workstation.toml):
#   [[components.codex.options.plugins]]          # one table per plugin
#   spec = "NAME@MARKETPLACE"
#   marketplace = "OWNER/REPO"                   # optional
#   minimumAt = "<versions.lock.json path>"       # optional
#   requiredSkillDirectories = ["<dir>", ...]     # optional
#   trackAt = "<versions.lock.json path>"         # optional, with watched
#   watched = ["<path pattern>", ...]
# A non-empty list adds the agentsPost hook plugins.sh, which adds missing
# Git marketplaces that entries name and installs missing plugins (agents
# install) and verifies every listed one (both modes). Codex refreshes
# configured Git marketplaces itself. Each trackAt entry (source and observed_marketplace_revision)
# adds a git-compare review row of the marketplace for its watched paths,
# with every method (lib/plugin-tracking.nix).
#   expectedPath = "~/.local/bin/codex"           # optional: the codex a login
#                                                 # shell must run first
# With the shell component the E2E hook codex-login-path (e2e-login-path.sh,
# for the profiles of the shell component) checks that the first codex on
# the PATH of an interactive login zsh is the expected one: expectedPath,
# else the official-binary destination ~/.local/bin/codex; without either
# it reports more than one codex on PATH. With official-binary the E2E hook
# codex-code-mode-host (e2e-code-mode-host.sh) checks that the codex found
# can start its helper. Invalid options fail the evaluation with every problem
# listed.
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
    elemAt
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

  # The login path check needs the zsh of the shell component, so it runs
  # only where that component is active: its profiles scope the hook.
  shell =
    config.dotsteward.components.shell or {
      enable = false;
      profiles = null;
    };

  platform = dsLib.platform.platformOf system;

  # The official releases: per platform one archive holding one member, the
  # binary, and one holding its Code Mode helper, which it starts from the
  # directory of its resolved executable.
  repo = "openai/codex";
  tagPrefix = "rust-v";
  releases = {
    linux = {
      asset = "codex-x86_64-unknown-linux-musl.tar.gz";
      member = "codex-x86_64-unknown-linux-musl";
      helperAsset = "codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz";
      helperMember = "codex-code-mode-host-x86_64-unknown-linux-musl";
    };
    darwin = {
      asset = "codex-aarch64-apple-darwin.tar.gz";
      member = "codex-aarch64-apple-darwin";
      helperAsset = "codex-code-mode-host-aarch64-apple-darwin.tar.gz";
      helperMember = "codex-code-mode-host-aarch64-apple-darwin";
    };
  };
  defaultMethod = "official-binary";
  pinOf = platformName: "agent_tools.codex.${platformName}";
  helperPinOf = platformName: "agent_tools.codex-code-mode-host.${platformName}";
  helperFile = "codex-code-mode-host";
  # The first release whose default features start the helper: it ships from
  # 0.143.0, where the feature code_mode_host is still off.
  helperSince = "0.144.0";

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
  # A lock from before the helper pin stays valid: an older version does not
  # need it, and a machine may already have the file (the method and the E2E
  # hook decide by what is installed).
  helperPinnedPlatforms = filter (platformName: lockAt (helperPinOf platformName) != null) pinnedPlatforms;

  # --- options ------------------------------------------------------------------

  componentOptions = component.options;
  plugins = componentOptions.plugins or [ ];
  pluginList = if isList plugins then plugins else [ ];
  tracking = dsLib.pluginTracking { inherit pins; };

  knownOptions = [
    "plugins"
    "expectedPath"
  ];
  expectedPath = componentOptions.expectedPath or null;
  knownPluginKeys = [
    "spec"
    "marketplace"
    "minimumAt"
    "requiredSkillDirectories"
  ]
  ++ tracking.keys;

  specPattern = "[A-Za-z0-9._-]+@[A-Za-z0-9._-]+";
  repoPattern = "[A-Za-z0-9._-]+/[A-Za-z0-9._-]+";
  isRepo = value: isString value && match repoPattern value != null;
  # The marketplace name of a valid spec.
  marketplaceOf = spec: elemAt (match "[^@]+@(.+)" spec) 0;
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
      # One marketplace name comes from one repository.
      marketplaceProblems =
        if !(plugin ? marketplace) then
          [ ]
        else if !isRepo plugin.marketplace then
          [ "${at}.marketplace must be a GitHub repository OWNER/REPO, got ${toJSON plugin.marketplace}" ]
        else
          let
            market = marketplaceOf spec;
            clash = lib.findFirst (
              position:
              let
                other = elemAt pluginList position;
              in
              isAttrs other
              && isRepo (other.marketplace or null)
              && isString (other.spec or null)
              && match specPattern other.spec != null
              && marketplaceOf other.spec == market
              && other.marketplace != plugin.marketplace
            ) null (lib.range 0 (index - 1));
          in
          lib.optional (validSpec && clash != null)
            "${at}.marketplace is ${toJSON plugin.marketplace} but options.plugins[${toString clash}] adds the marketplace ${market} from ${toJSON (elemAt pluginList clash).marketplace}";
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
      ++ marketplaceProblems
      ++ minimumProblems
      ++ skillProblems
      ++ tracking.problems at plugin;

  optionProblems =
    map (key: "unknown option ${key} (known: ${lib.concatStringsSep ", " knownOptions})") (
      filter (key: !elem key knownOptions) (attrNames componentOptions)
    )
    ++ lib.optional (
      expectedPath != null && !(isString expectedPath && match "(~/|/).+" expectedPath != null)
    ) "options.expectedPath must be a home path (~/...) or an absolute path, got ${toJSON expectedPath}"
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
        companions = [
          {
            pin = helperPinOf platform;
            member = releases.${platform}.helperMember;
            file = helperFile;
            since = helperSince;
          }
        ];
      };
      external = {
        command = "codex";
        versionArgv = [ "--version" ];
      };
    };

    pins = {
      rules =
        map (platformName: {
          kind = "download-pin";
          name = "release-${platformName}";
          at = pinOf platformName;
          url_contains = "https://github.com/${repo}/releases/download/${tagPrefix}{.version}/${releases.${platformName}.asset}";
        }) pinnedPlatforms
        ++ lib.concatMap (platformName: [
          {
            kind = "download-pin";
            name = "helper-${platformName}";
            at = helperPinOf platformName;
            url_contains = "https://github.com/${repo}/releases/download/${tagPrefix}{.version}/${releases.${platformName}.helperAsset}";
          }
          # One release: the binary and its helper move together.
          {
            kind = "derive";
            name = "helper-version-${platformName}";
            to = "${helperPinOf platformName}.version";
            from = "${pinOf platformName}.version";
          }
        ]) helperPinnedPlatforms;
      latest =
        map (platformName: {
          id = pinOf platformName;
          adapter = "github-release";
          inherit repo;
          tag_prefix = tagPrefix;
          at = pinOf platformName;
          inherit (releases.${platformName}) asset;
        }) pinnedPlatforms
        ++ map (platformName: {
          id = helperPinOf platformName;
          adapter = "github-release";
          inherit repo;
          tag_prefix = tagPrefix;
          at = helperPinOf platformName;
          asset = releases.${platformName}.helperAsset;
        }) helperPinnedPlatforms
        ++ tracking.latest pluginList;
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

    # It only reads, so it runs in parallel with the hooks next to it.
    checks.e2e =
      lib.optional shell.enable {
        name = "codex-login-path";
        script = ./e2e-login-path.sh;
        phase = "main";
        parallel = true;
        inherit (shell) profiles;
      }
      # Not parallel: every codex start, --version too, replaces its links under
      # $CODEX_HOME/tmp/arg0-linux.
      ++ lib.optional (component.method == "official-binary") {
        name = "codex-code-mode-host";
        script = ./e2e-code-mode-host.sh;
        phase = "main";
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
