# The opencode-pi catalog component: the OpenCode and Pi coding
# agents, their discovery of the shared skills and the Pi agent rules link.
#
# OpenCode, on Linux and darwin alike:
#   official-binary (default)  the official release archive of the platform
#                               (GitHub releases of anomalyco/opencode, tags
#                               v<version>), verified by size and SHA-256
#                               from the release pin of the platform in
#                               versions.lock.json (agent_tools.opencode on
#                               Linux, agent_tools.opencode-darwin on darwin),
#                               its member opencode installed as
#                               ~/.local/bin/opencode; at-least keeps a newer
#                               self-updated binary
#   external                    installed by the user; opencode is expected
#                               on PATH, at least at the pinned version
# Pi is always a Nix package (package.nix, pi-package.nix), added to
# home.packages wherever the component is active, whatever the OpenCode
# method is.
#
# Checks: the Pi probes (version against the skills lock mirror nix_tools.pi,
# the --help flags the agents rely on) and three agents checks in probes/:
# OpenCode runs, OpenCode's /skill API and Pi's RPC get_commands both list
# every expected skill.
{
  config,
  lib,
  profile,
  packages,
  dotsteward,
  ...
}:
let
  inherit (builtins) elem filter;

  name = "opencode-pi";
  inherit (dotsteward) cfg system;
  dsLib = dotsteward.lib;
  component = config.dotsteward.components.${name};

  platform = dsLib.platform.platformOf system;

  # The official releases: one archive per platform, each holding the
  # single member opencode.
  repo = "anomalyco/opencode";
  tagPrefix = "v";
  releases = {
    linux = {
      asset = "opencode-linux-x64.tar.gz";
      pin = "agent_tools.opencode";
    };
    darwin = {
      asset = "opencode-darwin-arm64.zip";
      pin = "agent_tools.opencode-darwin";
    };
  };
  defaultMethod = "official-binary";

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
  pinned = platformName: elem platformName pinnedPlatforms;

  # Pi: the package set's pi (an instance may replace it through
  # extraPackages), required only where the component is active.
  piPackage =
    packages.pi
      or (throw "dotsteward: component ${name} needs the package pi (modules/components/${name}/package.nix)");
  active =
    component.enable
    && (component.profiles == null || elem profile component.profiles)
    && elem platform component.platforms;

  modelDataTemplate = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-{agent_tools.pi.version}.tgz";

  piRules = [
    {
      kind = "derive";
      name = "pi-nix-package";
      to = "nix_packages.pi.expected";
      from = "agent_tools.pi.version";
      formats = {
        "agent_tools.pi.tag_revision" = "hex40";
        "agent_tools.pi.source_nix_sha256" = "sri";
        "agent_tools.pi.npm_dependencies_nix_sha256" = "sri";
        "agent_tools.pi.model_data_nix_sha256" = "sri";
      };
    }
    {
      kind = "derive";
      name = "pi-official-tag";
      to = "agent_tools.pi.official_tag";
      template = "v{agent_tools.pi.version}";
    }
    {
      kind = "derive";
      name = "pi-model-data-url";
      to = "agent_tools.pi.model_data_url";
      template = modelDataTemplate;
    }
    {
      kind = "skills-lock-mirror";
      name = "pi-nix-tool";
      pairs = [
        {
          from = "nix_packages.pi.resolved";
          to = "skills:nix_tools.pi";
        }
      ];
    }
  ];

  releaseRule = platformName: {
    kind = "download-pin";
    name = "opencode-release-${platformName}";
    at = releases.${platformName}.pin;
    version_field = "minimum_version";
    url_contains = "https://github.com/${repo}/releases/download/${tagPrefix}{.minimum_version}/${releases.${platformName}.asset}";
    formats.".source_revision" = "hex40";
  };

  # The skills lock mirror of the Linux release (release_tools.opencode),
  # in the field order of the reference check.
  releaseToolPair = field: target: {
    from = "${releases.linux.pin}.${field}";
    to = "skills:release_tools.opencode.${target}";
  };
  releaseToolRule = {
    kind = "skills-lock-mirror";
    name = "opencode-release-tool";
    pairs = [
      (releaseToolPair "minimum_version" "version")
    ]
    ++ map (field: releaseToolPair field field) [
      "source_revision"
      "url"
      "size"
      "sha256"
      "native_auto_updates"
    ];
  };

  opencodeRules =
    lib.optionals (pinned "linux") [
      (releaseRule "linux")
      releaseToolRule
    ]
    ++ lib.optional (pinned "darwin") (releaseRule "darwin")
    # Both releases move together: the darwin pin follows the Linux version.
    ++ lib.optional (pinned "linux" && pinned "darwin") {
      kind = "derive";
      name = "opencode-same-version";
      to = "${releases.darwin.pin}.minimum_version";
      from = "${releases.linux.pin}.minimum_version";
    };
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
        inherit (releases.${platform}) pin;
        asset = lib.mapAttrs (_: release: release.asset) releases;
        member = "opencode";
        dest = "~/.local/bin/opencode";
        versionArgv = [ "--version" ];
        versionRegex = "([0-9]+([.][0-9]+){2})";
        policy = "at-least";
        verify = "sha256";
      };
      external = {
        command = "opencode";
        versionArgv = [ "--version" ];
        minimum = releases.${platform}.pin;
      };
    };

    pins = {
      rules = piRules ++ opencodeRules;
      latest = [
        {
          id = "agent_tools.pi";
          adapter = "npm";
          at = "agent_tools.pi";
          package_at = "agent_tools.pi.package";
        }
      ]
      ++ map (platformName: {
        id = releases.${platformName}.pin;
        adapter = "github-release";
        inherit repo;
        tag_prefix = tagPrefix;
        at = releases.${platformName}.pin;
        inherit (releases.${platformName}) asset;
      }) pinnedPlatforms;
      resolvedVersions.pi = piPackage.version;
    };

    # OpenCode reads ~/.config/opencode/opencode.json on Linux and darwin
    # alike (JSON with comments allowed).
    settingsTargets.opencode = {
      path = "~/.config/opencode/opencode.json";
      format = "jsonc";
      createIfMissing = true;
    };

    agentRulesTargets = [ { path = ".pi/agent/AGENTS.md"; } ];
    bootstrap.backupPaths = [ "~/.pi/agent/AGENTS.md" ];
    rollback.managedLinks = [ "~/.pi/agent/AGENTS.md" ];

    probes = [
      {
        command = "pi";
        kind = "version";
        env.PI_OFFLINE = "1";
        expected = "skills:nix_tools.pi";
      }
      {
        command = "pi";
        kind = "features";
        argv = [ "--help" ];
        env.PI_OFFLINE = "1";
        needles = [
          "--offline"
          "--no-skills"
        ];
      }
      {
        command = "pi";
        kind = "features";
        argv = [
          "auth"
          "check"
          "--help"
        ];
        env.PI_OFFLINE = "1";
        needles = [
          "--json"
          "--no-refresh"
        ];
      }
    ];

    # The hooks are read in place from the framework source, so the
    # manifest mirror names them <dotsteward>/modules/components/opencode-pi/probes/<hook>.sh.
    checks = {
      commands = [
        "opencode"
        "pi"
      ];
      agents =
        map
          (hook: {
            name = hook;
            script = toString ./probes + "/${hook}.sh";
          })
          [
            "opencode-version"
            "opencode-skill-api"
            "pi-rpc"
          ];
    };

    docs = ./README.md;
  };

  home.packages = lib.optional active piPackage;
}
