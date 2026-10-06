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
# Only the pins of the resolved method are declared (download-pin rules and
# latest adapters), so an instance lock needs the entries of its method
# only; the official-binary pins cover the release platforms of every
# system in nix.systems, since one lock serves all of them. Settings
# targets, backups, the agent rules link and the skill link root do not
# depend on the method. Nothing joins home.packages: every method installs
# outside Home Manager.
{
  config,
  lib,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg system;

  name = "claude-code";
  method = config.dotsteward.components.${name}.method;

  # Release platforms of the native builds, per Nix system.
  releasePlatforms = {
    x86_64-linux = "linux-x64";
    aarch64-darwin = "darwin-arm64";
  };
  releasePlatformOf =
    system':
    releasePlatforms.${system'}
      or (throw "dotsteward: component claude-code has no native build for ${system'} (supported: ${lib.concatStringsSep ", " (lib.attrNames releasePlatforms)})");
  instanceReleasePlatforms = map releasePlatformOf cfg.nix.systems;

  releases = "https://downloads.claude.ai/claude-code-releases";
  aptBase = "https://downloads.claude.ai/claude-code/apt/stable";

  releasePin = platform: "agent_tools.${name}.${platform}";
  debPin = "desktop_packages.${name}";

  officialBinaryPins = {
    rules = map (platform: {
      kind = "download-pin";
      at = releasePin platform;
      url_contains = "/{.version}/${platform}/claude";
    }) instanceReleasePlatforms;
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
    }) instanceReleasePlatforms;
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

  pinsOf = {
    official-binary = officialBinaryPins;
    deb = debPins;
  };
  methodPins =
    pinsOf.${method} or {
      rules = [ ];
      latest = [ ];
    };
in
{
  dotsteward.components.${name} = {
    method = lib.mkDefault "official-binary";
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

    pins = { inherit (methodPins) rules latest; };

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
