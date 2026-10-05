# A synthetic component that sets every contract field.
{
  dotsteward.components.example-term = {
    enable = true;
    profiles = [ "main" ];
    platforms = [ "linux" ];
    method = "official-binary";
    supportedMethods = {
      linux = [
        "official-binary"
        "deb"
        "external"
      ];
      darwin = [ ];
    };
    options = {
      flag = true;
    };

    install = {
      nix.packages = [ ];
      official-binary = {
        pin = "agent_tools.example-term";
        asset = {
          linux = "example-term-{version}-x86_64-linux.tar.gz";
          darwin = "example-term-{version}-aarch64-darwin.tar.gz";
        };
        member = "example-term";
        dest = "~/.local/bin/example-term";
        versionArgv = [ "--version" ];
        versionRegex = "^example-term ([0-9.]+)$";
        policy = "at-least";
        verify = "sha256";
      };
      deb = {
        pin = "desktop_packages.example-term";
        packageNames = [
          "example-term"
          "example-term-bin"
        ];
        architecture = "amd64";
        apt = [ "example-app" ];
      };
      app-archive = {
        pin = "desktop_packages.example-term-darwin";
        appName = "Example Term.app";
      };
      external = {
        command = "example-term";
        versionArgv = [ "--version" ];
        minimum = "agent_tools.example-term.minimum";
      };
    };

    pins = {
      rules = [
        {
          kind = "derive";
          to = "nix_packages.example-term.expected";
          from = "agent_tools.example-term.version";
        }
      ];
      latest = [
        {
          id = "agent_tools.example-term";
          adapter = "github-release";
          repo = "example/example-term";
        }
      ];
      resolvedVersions = {
        example-term = "1.2.3";
      };
      flakeInputs = [ "example-term" ];
    };

    settingsTargets = {
      alpha = {
        path = "~/.config/example-term/alpha.json";
        format = "json";
        createIfMissing = true;
        reload = "example-term-reload";
      };
      delta = {
        path = {
          linux = "~/.config/Example Term/delta.json";
          darwin = "~/Library/Application Support/Example Term/delta.json";
        };
        format = "jsonc";
        createIfMissing = false;
        createMode = "0600";
        backup = false;
        reload = {
          command = [
            "example-term"
            "reload"
          ];
          timeout = 5;
        };
      };
    };
    reloadHooks.example-term-reload = {
      command = [
        "example-term"
        "server"
        "reload-config"
      ];
      timeout = 15;
      env = {
        HOME = "{home}";
      };
      unsetEnv = [ "EXAMPLE_TERM_SOCKET" ];
      requireCommand = "example-term";
      onSuccess = "log";
      onFailure = "silent";
    };

    probes = [
      {
        command = "example-term";
        kind = "version";
        expected = "versions:agent_tools.example-term.version";
        extract = "prefix:example-term ";
      }
      {
        command = "example-term";
        kind = "features";
        argv = [ "--help" ];
        env = {
          EXAMPLE_TERM_OFFLINE = "1";
        };
        needles = [ "--offline" ];
      }
    ];

    checks = {
      commands = [ "example-term" ];
      e2e = [
        {
          name = "example-term-config";
          script = ./hook.sh;
          phase = "late";
          profiles = [ "main" ];
        }
      ];
      agents = [
        {
          name = "example-term-agents";
          script = ./hook.sh;
        }
      ];
      floors = [
        {
          command = "example-term";
          argv = [ "--version" ];
          minimum = "agent_tools.example-term.minimum";
          compare = "semver";
        }
      ];
    };
    hooks = {
      preActivate = [
        {
          name = "pre";
          script = ./hook.sh;
        }
      ];
      desktopApply = [
        {
          name = "desktop";
          script = ./hook.sh;
        }
      ];
    };
    bootstrap = {
      backupPaths = [
        "~/.config/example-term/alpha.json"
        "/etc/example-term.conf"
      ];
      snapshots = [
        {
          name = "example-term-state";
          argv = [
            "example-term"
            "dump"
          ];
        }
      ];
      prerequisites.apt = [ "example-app" ];
    };
    rebuild.adoptPaths = [ "~/.config/example-term" ];
    rollback = {
      managedLinks = [ "~/.config/example-term/alpha.json" ];
      forceLinkedRestore = [ { path = "~/.config/example-term/rules.md"; } ];
    };
    preflight.detectors.example_detector = {
      argv = [
        "example-term"
        "detect"
      ];
      matchLine = "yes";
    };
    skillLayout = {
      legacyRoots = [ "~/.example-term/skills" ];
      linkRoots."~/.example-term/linked" = {
        targetPrefix = "../../.agents/skills/";
      };
      excludedSubtrees = [ ".system" ];
    };
    agentRulesTargets = [
      { path = ".example-term/AGENTS.md"; }
      {
        path = ".example-term/RULES.md";
        force = true;
      }
    ];
    gate.updatePaths = [ "components/example-term/[^/]+" ];
    docs = ./hook.sh;
  };
}
