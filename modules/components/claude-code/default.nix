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
{
  config,
  lib,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg system;
  inherit (dotsteward.lib.platform) platformOf;

  name = "claude-code";
  defaultMethod = "official-binary";
  platform = platformOf system;

  # The method of a platform of nix.systems: the resolved method of this
  # system's platform, the configured one (or the default) of the others.
  methodOn =
    platformName:
    if platformName == platform then
      config.dotsteward.components.${name}.method
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

  # The same on every system of the instance.
  instancePins = {
    rules = officialBinaryPins.rules ++ lib.optionals debOnLinux debPins.rules;
    latest = officialBinaryPins.latest ++ lib.optionals debOnLinux debPins.latest;
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

    docs = ./README.md;
  };
}
