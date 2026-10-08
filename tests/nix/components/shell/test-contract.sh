# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The shell component's contract values (3.4, 3.5), its packages, starship
# configuration and their reflection in the manifest and pinned versions.
# shellcheck source=tests/nix/components/shell/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/shell/helpers.sh"

# Contract values.
assert_eq '{"commands":["zsh","starship"],"docs":true,"flakeInputs":[],"latest":[{"adapter":"github-release","id":"nix_packages.starship","repo":"starship/starship"}],"method":"nix","packages":["zsh","starship"],"platforms":["linux","darwin"],"rules":[],"supportedMethods":{"darwin":["nix"],"linux":["nix"]}}' \
  "$(shell_eval "$shell_fixture" 'let c = home.dotsteward.components.shell; in {
    inherit (c) method platforms supportedMethods;
    packages = map lib.getName c.install.nix.packages;
    commands = c.checks.commands;
    inherit (c.pins) latest rules flakeInputs;
    docs = c.docs == repoRoot + "/modules/components/shell/README.md";
  }' | jq -cS .)" "contract values"

assert_eq '{"backupPaths":["~/.zshrc","/etc/shells"],"loginShell":"$HOME/.nix-profile/bin/zsh","managedLinks":["~/.zshrc","~/.config/starship.toml"],"probes":[{"argv":["--version"],"command":"starship","kind":"presence"}]}' \
  "$(shell_eval "$shell_fixture" 'let c = home.dotsteward.components.shell; in {
    backupPaths = c.bootstrap.backupPaths;
    managedLinks = c.rollback.managedLinks;
    probes = map (p: { inherit (p) command kind argv; }) c.probes;
    loginShell = home.dotsteward.loginShell.path;
  }' | jq -cS .)" "backup paths, managed links, probe and login shell"

# The starship package: the locked nixpkgs starship built from the pinned
# tag with the pinned source and cargo hashes, tests off; published as
# packages.<system>.starship and shared by home.packages and programs.starship.
assert_eq '{"cargoHash":"sha256-IO/H75FKU3/2oAJ8AKerGujMDfun8w4fV7gETMxWOt0=","doCheck":false,"programs":true,"published":true,"srcHash":"sha256-pStNE8SMMVavL3ld6RO+5QQRJPXpqlU3asccS2tUoMQ=","tag":"v1.26.0","version":"1.26.0"}' \
  "$(shell_eval "$shell_fixture" 'let
    starship = i.packages.x86_64-linux.starship;
    installed = lib.findFirst (p: lib.getName p == "starship") null home.dotsteward.components.shell.install.nix.packages;
  in {
    inherit (starship) version doCheck;
    tag = starship.src.tag;
    srcHash = starship.src.outputHash;
    cargoHash = starship.cargoDeps.vendorStaging.outputHash;
    published = installed.outPath == starship.outPath;
    programs = home.programs.starship.package.outPath == starship.outPath;
  }' | jq -cS .)" "starship package"

assert_eq 'true' \
  "$(shell_eval "$shell_fixture" '(lib.findFirst (p: lib.getName p == "zsh") null home.home.packages).outPath == pkgs.zsh.outPath')" \
  "zsh from the locked nixpkgs"

# The starship override is the nixpkgs package with only these attributes
# changed (so the store path equals the reference definition).
assert_eq 'true' \
  "$(shell_eval "$shell_fixture" 'let
    pins = builtins.fromJSON (builtins.readFile (/. + "'"$shell_fixture"'/versions.lock.json"));
    reference = pkgs.starship.overrideAttrs (_old: rec {
      version = pins.nix_packages.starship.expected;
      src = pkgs.fetchFromGitHub {
        owner = "starship";
        repo = "starship";
        tag = "v${version}";
        hash = pins.nix_packages.starship.source_nix_sha256;
      };
      cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
        inherit src;
        hash = pins.nix_packages.starship.cargo_nix_sha256;
      };
      doCheck = false;
    });
  in i.packages.x86_64-linux.starship.outPath == reference.outPath')" "reference store path"

# programs.starship: enabled with every shell integration off (the .zshrc
# starship-init block initializes it); settings come from the instance.
assert_eq '{"bash":false,"enable":true,"fish":false,"ion":false,"nushell":false,"settings":{"add_newline":false,"character":{"success_symbol":"[>](bold green)"},"format":"$directory$git_branch$character"},"zsh":false}' \
  "$(shell_eval "$shell_fixture" 'let s = home.programs.starship; in {
    inherit (s) enable settings;
    bash = s.enableBashIntegration;
    zsh = s.enableZshIntegration;
    fish = s.enableFishIntegration;
    ion = s.enableIonIntegration;
    nushell = s.enableNushellIntegration;
  }' | jq -cS .)" "programs.starship"
assert_eq 'true' "$(shell_eval "$shell_fixture" 'home.home.file ? ${home.programs.starship.configPath}')" "starship.toml"
assert_eq 'false' "$(shell_eval "$shell_fixture" 'home.programs.zsh.enable')" "programs.zsh stays off"

# Without starship settings Home Manager writes no starship.toml, so it is
# not a managed link either.
bare=$(instance_copy "$shell_fixture")
rm "$bare/home.nix"
assert_eq '{"file":false,"managedLinks":["~/.zshrc"]}' \
  "$(shell_eval "$bare" '{
    file = home.home.file ? ${home.programs.starship.configPath};
    managedLinks = home.dotsteward.components.shell.rollback.managedLinks;
  }' | jq -cS .)" "no settings"

# Pinned versions: core tomlkit plus the component's zsh and starship.
assert_eq 'true' \
  "$(shell_eval "$shell_fixture" 'i.lib.pinnedVersions == {
    tomlkit = pkgs.python3Packages.tomlkit.version;
    zsh = pkgs.zsh.version;
    starship = "1.26.0";
  }')" "pinned versions"

# The manifest carries the contributions.
manifest=$(shell_eval "$shell_fixture" 'storeless i.dotstewardManifest.x86_64-linux')
json_check "$manifest" '[.components[] | {name, source, method, modes}]' \
  '[{"method":"nix","modes":{"fresh":"fresh","workstation":"adopt"},"name":"shell","source":"catalog"}]'
json_check "$manifest" '.login_shell' '"$HOME/.nix-profile/bin/zsh"'
json_check "$manifest" '[.backup_paths[] | select(. == "~/.zshrc" or . == "/etc/shells")]' '["~/.zshrc","/etc/shells"]'
json_check "$manifest" '[.managed_links[] | select(test("zshrc|starship"))]' '["~/.zshrc","~/.config/starship.toml"]'
json_check "$manifest" '[.probes[] | select(.component == "shell") | .command]' '["starship"]'
json_check "$manifest" '.pinned_versions.starship' '"1.26.0"'

# darwin: the same component on aarch64-darwin.
darwin=$(shell_eval "$shell_fixture" 'storeless i.dotstewardManifest.aarch64-darwin')
json_check "$darwin" '[.components[] | {name, method, platforms}]' \
  '[{"method":"nix","name":"shell","platforms":["linux","darwin"]}]'
assert_eq 'true' \
  "$(shell_eval "$shell_fixture" '(homeOf i "aarch64-darwin" "workstation").home.file ? ".zshrc"')" "darwin .zshrc"

# Profile scoping: with profiles = ["workstation"] the fresh profile gets no
# .zshrc, no zsh and no starship, and the manifest stays identical.
scoped=$(instance_copy "$shell_fixture")
sed -i 's/^\[components.shell\]$/&\nprofiles = ["workstation"]/' "$scoped/workstation.toml"
assert_eq '{"freshFile":false,"freshPackages":[],"freshStarship":false,"manifest":true,"workstationFile":true}' \
  "$(shell_eval "$scoped" 'let
    fresh = homeOf i "x86_64-linux" "fresh";
    names = map lib.getName fresh.home.packages;
  in {
    workstationFile = home.home.file ? ".zshrc";
    freshFile = fresh.home.file ? ".zshrc";
    freshStarship = fresh.programs.starship.enable;
    freshPackages = lib.filter (n: n == "zsh" || n == "starship") names;
    manifest = (storeless fresh.dotsteward.manifest) == (storeless home.dotsteward.manifest);
  }' | jq -cS .)" "profile scoping"

# A lock without the starship pins names the component.
nopin=$(instance_copy "$shell_fixture")
jq 'del(.nix_packages.starship)' "$shell_fixture/versions.lock.json" >"$nopin/versions.lock.json"
shell_fails "$nopin" 'i.packages.x86_64-linux.starship.version' \
  "dotsteward: versions.lock.json lacks nix_packages.starship.expected (required by component shell)"
