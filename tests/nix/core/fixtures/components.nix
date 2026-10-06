# Synthetic components for the core tests, with the values mkInstance and
# the component modules would set:
#   shell         enabled per workstation.toml; drives loginShell.path only
#   example-app   method nix, every profile, one agent rules target
#   example-term  method official-binary, profiles from workstation.toml,
#                 every contribution core aggregates
# enable and profiles come from [components.<name>] like mkInstance sets them.
{
  pkgs,
  dotsteward,
  ...
}:
let
  inherit (dotsteward) cfg root;
  table = name: cfg.components.${name} or { };
  enabled = name: (table name).enable or false;
  profiles = name: (table name).profiles or null;
in
{
  dotsteward.components = {
    shell = {
      enable = enabled "shell";
      profiles = profiles "shell";
      method = "nix";
    };

    example-app = {
      enable = enabled "example-app";
      profiles = profiles "example-app";
      method = "nix";
      supportedMethods = {
        linux = [ "nix" ];
        darwin = [ "nix" ];
      };
      install.nix.packages = [ (pkgs.writeShellScriptBin "example-app" "echo example-app 1.0.0") ];
      agentRulesTargets = [ { path = ".example-app/AGENTS.md"; } ];
      rollback.managedLinks = [ "~/.example-app/AGENTS.md" ];
      bootstrap.backupPaths = [
        "~/.example-app/AGENTS.md"
        "~/.config/example-app"
      ];
      settingsTargets.alpha = {
        path = "~/.config/example-app/alpha.json";
        format = "json";
        createIfMissing = true;
      };
      probes = [
        {
          command = "example-app";
          kind = "presence";
        }
      ];
      checks.commands = [ "example-app" ];
      pins.resolvedVersions.example-app = "1.0.0";
    };

    example-term = {
      enable = enabled "example-term";
      profiles = profiles "example-term";
      method = "official-binary";
      supportedMethods = {
        linux = [
          "official-binary"
          "nix"
        ];
        darwin = [ "official-binary" ];
      };
      options.flag = true;
      install = {
        # Not installed by Home Manager: the resolved method is official-binary.
        nix.packages = [ (pkgs.writeShellScriptBin "example-term" "echo example-term 1.2.3") ];
        official-binary = {
          pin = "agent_tools.example-term";
          asset = {
            linux = "example-term-{version}-x86_64-linux.tar.gz";
            darwin = "example-term-{version}-aarch64-darwin.tar.gz";
          };
          member = "example-term";
          dest = "~/.local/bin/example-term";
          versionArgv = [ "--version" ];
          versionRegex = "example-term ([0-9.]+)";
          policy = "at-least";
          verify = "sha256";
        };
      };
      agentRulesTargets = [
        {
          path = ".example-term/RULES.md";
          force = true;
        }
      ];
      rollback = {
        managedLinks = [ "~/.example-term/RULES.md" ];
        forceLinkedRestore = [ { path = "~/.example-term/RULES.md"; } ];
      };
      rebuild.adoptPaths = [ "~/.config/example-term/state" ];
      bootstrap = {
        backupPaths = [
          "~/.config/example-term/beta.toml"
          "/etc/shells"
          "~/.config/example-app"
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
        prerequisites.apt = [ "example-term-deps" ];
      };
      settingsTargets = {
        beta = {
          path = {
            linux = "~/.config/example-term/beta.toml";
            darwin = "~/Library/Application Support/example-term/beta.toml";
          };
          format = "toml";
          createIfMissing = true;
          createMode = "0600";
          reload = "example-term-reload";
        };
        delta = {
          path = "~/.config/example-term/delta.jsonc";
          format = "jsonc";
          createIfMissing = false;
          backup = false;
          reload = {
            command = [
              "example-term"
              "reload"
              "{home}"
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
        env.HOME = "{home}";
        unsetEnv = [ "EXAMPLE_TERM_SOCKET" ];
        requireCommand = "example-term";
        onSuccess = "log";
        onFailure = "silent";
      };
      probes = [
        {
          command = "example-term";
          kind = "version";
          extract = "prefix:example-term ";
          expected = "versions:agent_tools.example-term.version";
        }
      ];
      checks = {
        commands = [
          "example-term"
          "jq"
        ];
        e2e = [
          {
            name = "example-term-config";
            script = root + "/hook.sh";
            phase = "late";
            profiles = [ "workstation" ];
          }
        ];
        agents = [
          {
            name = "example-term-agents";
            script = root + "/hook.sh";
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
      hooks.preActivate = [
        {
          name = "example-term-pre";
          script = root + "/hook.sh";
        }
      ];
      preflight.detectors.example_detector = {
        argv = [
          "example-term"
          "detect"
        ];
        matchLine = "yes";
      };
      skillLayout = {
        legacyRoots = [ "~/.example-term/skills" ];
        linkRoots."~/.example-term/linked".targetPrefix = "../../.agents/skills/";
        excludedSubtrees = [ ".system" ];
      };
      gate.updatePaths = [ "components/example-term/[^/]+" ];
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
        resolvedVersions.example-term = "1.2.3";
        flakeInputs = [ "example-term" ];
      };
    };
  };
}
