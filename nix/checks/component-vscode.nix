# The vscode catalog component (tests/nix/components/vscode): its contract
# values on both systems as lib.mkInstance evaluates them, the methods and
# their pins, the set_default_editor option, the deb install block driven
# through `dotsteward install`, the seed and the pins engine over it, the
# JSONC settings target driven end to end through the settings engine, the
# vendor-repository guard and the docs. The tests evaluate instances with
# nix-instantiate against an isolated store, so the sandbox needs Nix and
# the nixpkgs and home-manager sources; a setup hook exports their paths.
#
# Then the fixture instance is built inside this flake: the generation
# exports the editor variables, ships the manifest with the settings target
# and the pins declarations, and its local-maintained-files alias writes
# VS Code's settings.json on a fresh home.
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-component-vscode-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };

  fixture = import ../../tests/nix/components/vscode/flake-instance.nix { inherit self dsLib; };
  generation = fixture.instance.checks.x86_64-linux.home;
  buffer = ../../tests/nix/components/vscode/fixtures/instance/local-maintained-files;
in
cli.mkTestCheck {
  name = "component-vscode";
  paths = [ "tests/nix/components/vscode" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
    testEnv
  ];
  postCheck = ''
    fail() {
      printf 'component-vscode: %s\n' "$*" >&2
      exit 1
    }
    shellcheck -x tests/nix/components/vscode/*.sh

    # The generation exports exactly the editor variables of the option.
    gen=${generation}
    [[ -x $gen/activate ]] || fail "$gen is not an activation package"
    vars=$gen/home-path/etc/profile.d/hm-session-vars.sh
    [[ -f $vars ]] || fail "missing $vars"
    for line in 'export EDITOR="code"' 'export VISUAL="code"' 'export GIT_EDITOR="code --wait"'; do
      grep -qxF "$line" "$vars" || fail "hm-session-vars.sh lacks: $line"
    done

    # The manifest carries the settings target and the pins declarations.
    jq -e '.settings_targets["vscode-settings"] == {
        component: "vscode", path: "~/.config/Code/User/settings.json", format: "jsonc",
        create_if_missing: true, create_mode: "0644", backup: true, reload: null }
      and ([.components[] | select(.name == "vscode") | .method, .install.pin] == ["deb", "desktop_packages.vscode"])
      and ([.pins.rules[] | select(.component == "vscode") | .at]
        == ["desktop_packages.vscode", "desktop_packages.vscode-darwin-arm64"])
      and ([.pins.latest[] | select(.component == "vscode") | .adapter] == ["official-manifest", "official-manifest"])' \
      "$gen/home-path/share/dotsteward/manifest.json" >/dev/null || fail "the generation manifest"

    # The generation's alias applies the instance buffer to a fresh home.
    work=$TMPDIR/vscode-e2e
    mkdir -p "$work/home" "$work/repo"
    cp -R ${buffer} "$work/repo/local-maintained-files"
    chmod -R u+w "$work/repo"
    git -C "$work/repo" init -q -b main
    git -C "$work/repo" add -A
    git -C "$work/repo" -c user.name=check -c user.email=check@example.invalid commit -q -m buffer
    PATH="$gen/home-path/bin:$PATH" \
      local-maintained-files --repo "$work/repo" --home "$work/home" --state-dir "$work/state" apply
    settings=$work/home/.config/Code/User/settings.json
    [[ -f $settings && $(stat -c %a "$settings") == 644 ]] || fail "settings.json was not created 0644"
    jq -e '.["editor.fontSize"] == 14 and .["files.autoSave"] == "afterDelay"' "$settings" >/dev/null ||
      fail "the tracked settings were not written: $(<"$settings")"
  '';
}
