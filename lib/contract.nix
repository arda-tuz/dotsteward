# The component contract: option types of dotsteward.components.<name>.
#
# Every component, catalog or instance-private, is a Home Manager module that
# sets dotsteward.components.<name>; core declares the option with
# `componentsOption`. The consumers are mkInstance, the manifest and through
# it the CLI (installer methods, settings engine, probes, hooks, E2E runner).
#
# Defaults: a field the spec gives a default keeps it; lists default to [ ],
# attribute sets to { } and nullable fields to null. Scalars without a
# default (method, the fields of an install block, a settings target's
# format) must be set when they are read; only the install block of the
# resolved method is ever read, so unused blocks may stay empty.
#
# Exports: methods, systemMethods, platforms, hookPhases, ruleKinds,
# latestAdapters, types.<name>, componentModule, componentsOption.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  methods = [
    "nix"
    "official-binary"
    "deb"
    "app-archive"
    "external"
  ];

  # System-level methods: skipped in adopt mode.
  systemMethods = [
    "deb"
    "app-archive"
  ];

  platforms = [
    "linux"
    "darwin"
  ];

  hookPhases = [
    "early"
    "main"
    "late"
  ];

  # Pin rule kinds of the pins engine.
  ruleKinds = [
    "flake-inputs"
    "nix-package-format"
    "derive"
    "download-pin"
    "text-guard"
    "no-literal"
    "npm-bundle"
    "skills-lock-mirror"
    "minimum-version"
    "asset-digest"
    "nix-resolved"
    "skill-digests"
  ];

  # Adapters of `pins latest`.
  latestAdapters = [
    "github-release"
    "npm"
    "apt-index"
    "deb-url"
    "official-manifest"
    "nix-release"
    "channel-head"
    "git-compare"
    "skill-source"
    "local-apt"
    "manual"
    "follows"
    "framework"
  ];

  option = type: description: mkOption { inherit type description; };
  optionDefault =
    type: default: description:
    mkOption { inherit type default description; };
  list = type: description: optionDefault (types.listOf type) [ ] description;
  attrs = type: description: optionDefault (types.attrsOf type) { } description;
  nullable = type: description: optionDefault (types.nullOr type) null description;

  # --- Value types ------------------------------------------------------------

  lockPath = types.strMatching "[A-Za-z0-9_][A-Za-z0-9_+-]*(\\.[A-Za-z0-9_][A-Za-z0-9_+-]*)*" // {
    description = "versions.lock.json key path (dot separated)";
  };

  method = types.enum methods;
  platform = types.enum platforms;

  # "~/..." paths, expanded with the home directory.
  homePath = types.strMatching "~/.+" // {
    description = "home path (~/...)";
  };

  # "~/..." or absolute paths.
  hostPath = types.strMatching "~?/.+" // {
    description = "home path (~/...) or absolute path";
  };

  # Paths relative to the home directory (Home Manager home.file keys).
  homeRelativePath = types.strMatching "[^/~].*" // {
    description = "path relative to the home directory";
  };

  fileMode = types.strMatching "0[0-7]{3}" // {
    description = "octal file mode (0644)";
  };

  perPlatform =
    type:
    types.submodule {
      options = {
        linux = option type "Value on Linux.";
        darwin = option type "Value on darwin.";
      };
    };

  # A settings target path: one home path, or one per platform.
  perPlatformPath = types.either homePath (perPlatform homePath);

  # JSON-like free-form attributes (pin rules and latest declarations, whose
  # fields depend on their kind and belong to the pins engine).
  freeform = types.attrsOf types.anything;

  # --- Records ----------------------------------------------------------------

  hookSpec = types.submodule {
    options = {
      name = option types.str "Hook name (unique within the component and list).";
      script = option types.path "Executable in the component directory; runs with the hook environment.";
      profiles = nullable (types.listOf types.str) "Profiles where the hook runs; null: every profile.";
      phase = optionDefault (types.enum hookPhases) "main" "E2E phase (checks.e2e only).";
    };
  };

  reloadSpec = types.submodule {
    options = {
      command = option (types.listOf types.str) "Reload argv; {home} expands to the home directory.";
      timeout =
        optionDefault types.ints.positive 15
          "Seconds before the reload is abandoned with a warning.";
      env = attrs types.str "Environment variables set for the command.";
      unsetEnv = list types.str "Environment variables removed for the command.";
      requireCommand = nullable types.str "Skip the reload when this command is missing.";
      onSuccess = optionDefault (types.enum [
        "log"
        "silent"
      ]) "silent" "Report a successful reload.";
      onFailure = optionDefault (types.enum [
        "warn"
        "silent"
      ]) "warn" "Report a failed reload.";
    };
  };

  probeSpec = types.submodule {
    options = {
      command = option types.str "Command under test (looked up on PATH).";
      kind =
        option
          (types.enum [
            "version"
            "presence"
            "features"
          ])
          "version: extracted output equals expected; presence: exits 0; features: output contains every needle.";
      argv = optionDefault (types.listOf types.str) [ "--version" ] "Arguments.";
      env = attrs types.str "Environment variables set for the probe.";
      extract =
        optionDefault (types.strMatching "first-line|printf-vd|field:.+|prefix:.*|regex:.+") "first-line"
          "Version extractor: first-line, field:<label>, prefix:<text>, printf-vd or regex:<re>.";
      expected = nullable (types.strMatching "(versions|skills):.+") "Expected version: versions:<lock path> or skills:<skills lock path>.";
      needles = list types.str "Strings the output must contain (features).";
      profiles = nullable (types.listOf types.str) "Profiles where the probe runs; null: every profile.";
    };
  };

  ruleSpec = types.submodule {
    freeformType = freeform;
    options.kind = option (types.enum ruleKinds) "Pin rule kind; the other fields depend on it.";
  };

  latestSpec = types.submodule {
    freeformType = freeform;
    options = {
      id = option types.str "Report row id (for example agent_tools.<name>).";
      adapter = option (types.enum latestAdapters) "Latest adapter; the other fields depend on it.";
    };
  };

  settingsTarget = types.submodule {
    options = {
      path = option perPlatformPath "Target file: a home path or { linux; darwin; }.";
      format = option (types.enum [
        "json"
        "toml"
        "jsonc"
      ]) "File format.";
      createIfMissing = option types.bool "Create the file when a buffer entry applies and it is missing.";
      createMode = optionDefault fileMode "0644" "Mode of a created file.";
      backup = optionDefault types.bool true "Back up the file before the first write and in stage-0.";
      reload = nullable (types.either types.str reloadSpec) "Reload hook: a reloadHooks name or an inline spec.";
    };
  };

  installBlocks = {
    nix = {
      packages = list types.package "Packages added to home.packages.";
    };
    official-binary = {
      pin = option lockPath "Lock path of the release (version, digests).";
      asset = option (perPlatform types.str) "Release asset name template per platform.";
      member = option types.str "Archive member to install.";
      dest = option homePath "Install destination (~/.local/bin/<command>).";
      versionArgv = option (types.listOf types.str) "Arguments that print the version.";
      versionRegex = option types.str "Regex whose first group is the version.";
      policy = option (types.enum [
        "at-least"
        "exact"
      ]) "at-least keeps a newer self-updated binary.";
      verify = option (types.enum [
        "sha256"
        "sha256+sigstore"
      ]) "Download verification.";
    };
    deb = {
      pin = nullable lockPath "Lock path of the DEB download; null: apt only.";
      packageNames = list types.str "Package names (aliases allowed) asserted after download.";
      architecture = nullable types.str "Architecture asserted for the DEB.";
      verifyAfterInstall = optionDefault types.bool true "Verify the floor after installing.";
      apt = list types.str "Plain apt packages in the same transaction.";
    };
    app-archive = {
      pin = option lockPath "Lock path of the archive.";
      appName = option types.str "Application bundle name.";
      dest = optionDefault homePath "~/Applications" "Destination directory.";
    };
    external = {
      command = nullable types.str "Command expected on PATH.";
      versionArgv = nullable (types.listOf types.str) "Arguments that print the version.";
      minimum = nullable lockPath "Lock path of the minimum version.";
    };
  };

  submoduleOption =
    options: description: optionDefault (types.submodule { inherit options; }) { } description;

  componentModule = {
    options = {
      enable = optionDefault types.bool false "Set by mkInstance from [components.<name>].enable.";
      profiles = nullable (types.listOf types.str) "Profiles where the component is active; null: every profile.";
      platforms = optionDefault (types.listOf platform) platforms "Supported platforms.";
      method = option method "Resolved method: method_by_platform, then method, then the component default.";
      supportedMethods = submoduleOption {
        linux = list method "Methods supported on Linux.";
        darwin = list method "Methods supported on darwin.";
      } "Methods the component implements per platform.";
      options = attrs types.anything "[components.<name>].options of workstation.toml, set by mkInstance.";

      install = submoduleOption (lib.mapAttrs (
        name: blockOptions: submoduleOption blockOptions "Install block of the ${name} method."
      ) installBlocks) "Install blocks; only the block of the resolved method is used.";

      pins = submoduleOption {
        rules = list ruleSpec "Pin rules (pins engine).";
        latest = list latestSpec "Latest declarations (pins latest).";
        resolvedVersions = attrs types.str "Contribution to lib.pinnedVersions.";
        flakeInputs = list types.str "Instance flake inputs the component needs.";
      } "Pins contributions.";

      settingsTargets = attrs settingsTarget "Settings targets of the settings engine.";
      reloadHooks = attrs reloadSpec "Named reload hooks for settings targets.";

      probes = list probeSpec "CLI probes.";
      checks = submoduleOption {
        commands = list types.str "Commands E2E requires.";
        e2e = list hookSpec "E2E hooks.";
        agents = list hookSpec "agents check discovery steps.";
        floors = list (types.submodule {
          options = {
            command = option types.str "Command whose version is checked.";
            argv = option (types.listOf types.str) "Arguments that print the version.";
            minimum = option types.str "Minimum version or its lock path.";
            compare = option (types.enum [
              "dpkg"
              "semver"
            ]) "Version comparison.";
          };
        }) "Minimum version floors.";
      } "Checks.";

      hooks = submoduleOption (lib.genAttrs [
        "preActivate"
        "systemInstall"
        "postInstall"
        "forbid"
        "agentsInstall"
        "agentsMigrate"
        "agentsPost"
        "desktopApply"
      ] (name: list hookSpec "Hooks of the ${name} phase.")) "Phase hooks.";

      bootstrap = submoduleOption {
        backupPaths = list hostPath "Paths backed up by stage-0.";
        snapshots = list (types.submodule {
          options = {
            name = option types.str "Snapshot name.";
            argv = option (types.listOf types.str) "Command whose output is saved.";
            requireCommand = nullable types.str "Skip when this command is missing.";
          };
        }) "Command output snapshots taken by stage-0.";
        prerequisites = submoduleOption {
          apt = list types.str "apt packages installed before Nix.";
        } "Stage-0 prerequisites.";
      } "Bootstrap contributions.";

      rebuild = submoduleOption {
        adoptPaths = list hostPath "Existing files adopted by rebuild.";
      } "Rebuild contributions.";

      rollback = submoduleOption {
        managedLinks = list hostPath "Home Manager links checked and removed by rollback.";
        forceLinkedRestore = list (types.submodule {
          options = {
            path = option hostPath "Path restored as a regular file.";
            mode = optionDefault fileMode "0664" "Mode of the restored file.";
          };
        }) "Force-linked files restored by rollback.";
      } "Rollback contributions.";

      preflight = submoduleOption {
        detectors = attrs (types.submodule {
          options = {
            argv = option (types.listOf types.str) "Detector command.";
            matchLine = option types.str "Output line that means detected.";
          };
        }) "Named preflight detectors.";
      } "Preflight contributions.";

      skillLayout = submoduleOption {
        legacyRoots = list hostPath "Legacy skill roots searched and swept.";
        linkRoots = attrs (types.submodule {
          options.targetPrefix = option types.str "Relative link target prefix.";
        }) "Skill link roots and their target prefixes.";
        excludedSubtrees = list types.str "Subtrees never touched.";
      } "Skill layout contributions.";

      agentRulesTargets = list (types.submodule {
        options = {
          path = option homeRelativePath "Home-relative target of the agent rules file.";
          force = optionDefault types.bool false "Overwrite an existing file.";
        };
      }) "Agent rules targets.";

      gate = submoduleOption {
        updatePaths = list types.str "Extended regular expressions for the update-scope allowlist.";
      } "Gate contributions.";

      docs = nullable types.path "README.md of the component (required for catalog components).";
    };
  };
in
{
  inherit
    methods
    systemMethods
    platforms
    hookPhases
    ruleKinds
    latestAdapters
    componentModule
    ;

  types = {
    inherit
      lockPath
      method
      platform
      homePath
      hostPath
      homeRelativePath
      fileMode
      perPlatformPath
      hookSpec
      reloadSpec
      probeSpec
      ruleSpec
      latestSpec
      settingsTarget
      ;
    component = types.submodule componentModule;
  };

  # The declaration of dotsteward.components (used by modules/core).
  componentsOption = mkOption {
    type = types.attrsOf (types.submodule componentModule);
    default = { };
    description = "Component contract values, one entry per component.";
  };
}
