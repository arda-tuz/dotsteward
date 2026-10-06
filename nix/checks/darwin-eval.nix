# darwin evaluation (SPEC 12.3): the full darwin fixture instance
# (tests/fixtures/instances/full-darwin) evaluated for aarch64-darwin on
# x86_64-linux, never built; then the darwin platform layer
# (tests/cli/darwin).
#
# The instance is what `dotsteward init` makes of the framework template:
# the files of template/ with the fixture's files on top, plus the
# .dotsteward/ mirrors rendered from the evaluated instance (as
# checks.template-full does; the mirrors hold values of the framework under
# test, so they are never committed). The herdr flake input is a darwin
# stand-in package (an application input is never a framework input).
#
# Evaluated: every check of the instance on aarch64-darwin (the activation
# packages of the check and both profiles, the Pi and example-app packages,
# the manifest, contract and static checks) and the instance's
# homeConfigurations entry are instantiated by forcing their drvPath. The
# derivation paths and every other evaluated value reach this check only as
# strings without context (builtins.unsafeDiscardStringContext), so nothing
# darwin is built or substituted. The build compares the evaluated values
# with the expected ones: the systems of the derivations, the darwin
# manifest (components and resolved methods, the darwin settings paths, the
# login shell, the mirrors), and the check configuration (home directory,
# packages, the VS Code bundle's command directory on PATH, the editor
# variables, the agent rules links and the profile-scoped files). The
# instance contract of the darwin instance (static --sandbox, the offline
# pins check, settings validate against the evaluated darwin targets, the
# privacy scan) runs here with DOTSTEWARD_PLATFORM=darwin, as its
# instance-contract check would run it on a Mac.
#
# The darwin platform layer tests run first, with ShellCheck over the layer,
# its tests and the macOS tool doubles they use.
{
  self,
  pkgs,
  lib,
  dsLib,
  ...
}:
let
  inherit (builtins) toJSON unsafeDiscardStringContext;

  cli = dsLib.mkCli pkgs;

  darwin = "aarch64-darwin";
  darwinPkgs = self.inputs.nixpkgs.legacyPackages.${darwin};

  fixture = ../../tests/fixtures/instances/full-darwin;

  # The stand-in herdr input package (instantiated, never built): herdr
  # --version prints "herdr 0.9.3", the version the fixture lock pins.
  herdr =
    darwinPkgs.writeTextFile {
      name = "herdr-0.9.3";
      destination = "/bin/herdr";
      executable = true;
      text = ''
        #!${darwinPkgs.runtimeShell}
        if [ "''${1:-}" = --version ]; then
          echo "herdr 0.9.3"
        fi
      '';
    }
    // {
      pname = "herdr";
      version = "0.9.3";
    };

  instanceAt =
    root:
    dsLib.mkInstance {
      inherit root;
      inputs = {
        self.outPath = root;
        inherit (self.inputs) nixpkgs home-manager;
        dotsteward = self;
        herdr.packages.${darwin}.herdr = herdr;
      };
    };

  # The template with the fixture on top: what init writes, before sync.
  templateRoot = pkgs.runCommand "dotsteward-full-darwin-instance-template" { } ''
    cp -R ${../../template} "$out"
    chmod -R u+w "$out"
    cp -R ${fixture}/. "$out/"
  '';

  # The same instance with its current mirrors.
  root = pkgs.runCommand "dotsteward-full-darwin-instance" { } ''
    cp -R ${templateRoot} "$out"
    chmod -R u+w "$out"
    mkdir -p "$out/.dotsteward"
    ${lib.concatStrings (
      lib.mapAttrsToList (name: text: ''
        cp ${pkgs.writeText name text} "$out/.dotsteward/${name}"
      '') (instanceAt "${templateRoot}").dotstewardMirrors
    )}
  '';

  instance = instanceAt "${root}";
  checks = instance.checks.${darwin};
  home = instance.homeConfigurations.alice;
  hm = home.config;

  derivation = drv: {
    drvPath = unsafeDiscardStringContext drv.drvPath;
    inherit (drv) system;
  };

  # The evaluated darwin settings targets, in the format of the
  # generation's targets file (the darwin instance-contract check's own file
  # is a darwin derivation).
  manifest = instance.dotstewardManifest.${darwin};
  targetsFile = pkgs.writeText "dotsteward-settings-targets.json" (
    unsafeDiscardStringContext (toJSON {
      schema_version = 1;
      targets = manifest.settings_targets;
      inherit (manifest) reload_hooks;
    })
  );

  # Every evaluated value the build compares, as context-free JSON.
  report = pkgs.writeText "darwin-eval.json" (
    unsafeDiscardStringContext (toJSON {
      checks = lib.mapAttrs (_: derivation) checks;
      home_configuration = derivation home.activationPackage;
      inherit manifest;
      manifests = lib.attrNames instance.dotstewardManifest;
      mirrors = lib.attrNames instance.dotstewardMirrors;
      packages = lib.attrNames instance.packages.${darwin};
      config = {
        inherit (hm.home) homeDirectory username sessionPath;
        session_variables = hm.home.sessionVariables;
        home_packages = map lib.getName hm.home.packages;
        files = lib.sort lib.lessThan (
          lib.mapAttrsToList (_: file: file.target) (lib.filterAttrs (_: file: file.enable) hm.home.file)
        );
      };
      fresh_files = lib.sort lib.lessThan (
        lib.mapAttrsToList (_: file: file.target) (
          lib.filterAttrs (_: file: file.enable)
            (instance.lib.mkHome {
              username = "alice";
              homeDirectory = "/Users/alice";
              profile = "fresh";
              system = darwin;
            }).config.home.file
        )
      );
    })
  );
in
cli.mkTestCheck {
  name = "darwin-eval";
  paths = [ "tests/cli/darwin" ];
  nativeBuildInputs = [ pkgs.shellcheck ];
  postCheck = ''
    shellcheck -x cli/lib/platform-darwin.sh tests/cli/darwin/*.sh tests/cli/darwin/tools/*

    report=${report}
    fail() {
      printf 'darwin-eval: %s\n' "$*" >&2
      exit 1
    }
    expect() {
      jq -e "$1" "$report" >/dev/null || fail "$2: $(jq -c "''${3:-.}" "$report")"
    }

    # Every check of the darwin instance, no more and no less, is an
    # aarch64-darwin derivation that was instantiated.
    expect '.checks | keys == ["dotsteward-manifest", "example-app", "home", "home-fresh",
      "home-workstation", "instance-contract", "instance-static", "manifest-consistent", "pi"]' \
      "darwin checks" '.checks | keys'
    expect '[.checks[], .home_configuration] | all(.system == "aarch64-darwin")' \
      "derivation systems" '[.checks[] | .system]'
    expect '[.checks[], .home_configuration] | all(.drvPath | test("^/nix/store/[0-9a-z]{32}-.+[.]drv$"))' \
      "derivation paths" '[.checks[] | .drvPath]'
    expect '.home_configuration.drvPath == .checks.home.drvPath' "homeConfigurations.alice is the check profile" \
      '[.home_configuration.drvPath, .checks.home.drvPath]'
    expect '.checks.home.drvPath == .checks["home-workstation"].drvPath and .checks.home.drvPath != .checks["home-fresh"].drvPath' \
      "profile activation packages" '[.checks.home.drvPath, .checks["home-workstation"].drvPath, .checks["home-fresh"].drvPath]'
    expect '.manifests == ["aarch64-darwin"] and .mirrors == ["manifest.aarch64-darwin.json", "stage0.darwin.env"]' \
      "manifests and mirrors" '[.manifests, .mirrors]'
    expect '.packages | index("pi") != null and index("example-app") != null and index("dotsteward") != null' \
      "darwin packages" '.packages'

    # The darwin manifest: components in [components] order with their
    # darwin methods, darwin settings paths, the login shell.
    expect '.manifest.system == "aarch64-darwin" and .manifest.platform == "darwin"' "manifest system" '.manifest | [.system, .platform]'
    expect '[.manifest.components[] | {name, method}] == [
        {name: "shell", method: "nix"},
        {name: "herdr", method: "nix"},
        {name: "claude-code", method: "official-binary"},
        {name: "codex", method: "official-binary"},
        {name: "opencode-pi", method: "official-binary"},
        {name: "vscode", method: "app-archive"},
        {name: "example-app", method: "nix"},
        {name: "example-term", method: "nix"}
      ]' "manifest components" '[.manifest.components[] | {name, method}]'
    expect '.manifest.components[] | select(.name == "vscode") | .install
      | .pin == "desktop_packages.vscode-darwin-arm64" and .appName == "Visual Studio Code.app" and .dest == "~/Applications"' \
      "vscode app-archive block" '.manifest.components[] | select(.name == "vscode") | .install'
    expect '.manifest.settings_targets["vscode-settings"].path == "~/Library/Application Support/Code/User/settings.json"' \
      "vscode settings path" '.manifest.settings_targets["vscode-settings"]'
    expect '.manifest.settings_targets["example-term"].path == "~/Library/Application Support/example-term/config.toml"' \
      "example-term settings path" '.manifest.settings_targets["example-term"]'
    expect '[.manifest.settings_targets[].path] | all(startswith("~/"))' "settings paths" '[.manifest.settings_targets[].path]'
    expect '.manifest.login_shell == "$HOME/.nix-profile/bin/zsh"' "login shell" '.manifest.login_shell'

    # The check configuration of the darwin home.
    expect '.config.homeDirectory == "/Users/alice" and .config.username == "alice"' "identity" '.config | [.homeDirectory, .username]'
    expect '.config.sessionPath | index("$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin") != null' \
      "the VS Code bundle command directory on PATH" '.config.sessionPath'
    expect '.config.session_variables | .EDITOR == "code" and .VISUAL == "code" and .GIT_EDITOR == "code --wait"' \
      "editor variables" '.config.session_variables'
    expect '.config.home_packages as $p | ["zsh", "starship", "herdr", "pi-coding-agent", "example-app", "example-term"]
      | all(. as $name | $p | index($name) != null)' "home packages" '.config.home_packages'
    expect '.config.home_packages | index("code") == null and index("vscode") == null and index("claude") == null and index("codex") == null' \
      "packages installed outside Nix" '.config.home_packages'
    expect '.config.files as $f | [".claude/CLAUDE.md", ".codex/AGENTS.md", ".pi/agent/AGENTS.md",
      ".example-term/AGENTS.md", ".example-term/greeting", ".zshrc", ".config/starship.toml"]
      | all(. as $file | $f | index($file) != null)' "home files" '.config.files'
    expect '.fresh_files | index(".example-term/greeting") == null and index(".example-term/AGENTS.md") == null
      and index(".claude/CLAUDE.md") != null' "fresh profile files" '.fresh_files'

    # The instance contract of the darwin instance, as its instance-contract
    # check runs it on a Mac: the same commands of the packaged CLI over a
    # copy of the instance, with the evaluated darwin settings targets.
    instance=$TMPDIR/instance
    cp -R ${root} "$instance"
    chmod -R u+w "$instance"
    (
      cd "$instance"
      export HOME=$TMPDIR/home DOTSTEWARD_INSTANCE=$PWD DOTSTEWARD_PLATFORM=darwin
      mkdir -p "$HOME"
      ${lib.getExe cli} static --sandbox
      ${lib.getExe cli} pins check
      ${lib.getExe cli} settings --targets-file ${targetsFile} validate
      ${lib.getExe cli} scan --tree
    ) || fail "the instance contract of the darwin instance failed"
  '';
}
