# The herdr catalog component (tests/nix/components/herdr): its contract
# values on both systems as lib.mkInstance evaluates them, the missing-input
# errors, the seed, the E2E login-shell hook (run with zsh) and the settings
# target driven end to end through the settings engine. The tests evaluate
# instances with nix-instantiate against an isolated store, so the sandbox
# needs Nix and the nixpkgs and home-manager sources; a setup hook exports
# their paths.
#
# Then the fixture instance is built inside this flake with a stand-in herdr
# input: the generation installs the input's herdr, ships the manifest, and
# its local-maintained-files alias writes the herdr configuration and runs
# the reload hook with the generation's herdr.
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-component-herdr-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };

  fixture = import ../../tests/nix/components/herdr/flake-instance.nix { inherit self dsLib pkgs; };
  generation = fixture.instance.checks.x86_64-linux.home;
  buffer = ../../tests/nix/components/herdr/fixtures/instance/local-maintained-files;
in
cli.mkTestCheck {
  name = "component-herdr";
  paths = [ "tests/nix/components/herdr" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.zsh
    pkgs.shellcheck
    testEnv
  ];
  postCheck = ''
    fail() {
      printf 'component-herdr: %s\n' "$*" >&2
      exit 1
    }
    shellcheck -x modules/components/herdr/*.sh tests/nix/components/herdr/*.sh

    # The generation installs the input's herdr and ships the manifest.
    gen=${generation}
    [[ -x $gen/activate ]] || fail "$gen is not an activation package"
    [[ $(readlink -f "$gen/home-path/bin/herdr") == ${fixture.herdr}/bin/herdr ]] ||
      fail "home-path/bin/herdr is not the herdr input's package"
    [[ $("$gen/home-path/bin/herdr" --version) == "herdr 0.9.3" ]] || fail "herdr --version"
    jq -e '.settings_targets.herdr == {
        component: "herdr", path: "~/.config/herdr/config.toml", format: "toml",
        create_if_missing: true, create_mode: "0644", backup: true, reload: "herdr-server" }
      and .reload_hooks["herdr-server"].command == ["herdr", "server", "reload-config"]
      and .pins.resolved_versions.herdr == "0.9.3"' \
      "$gen/home-path/share/dotsteward/manifest.json" >/dev/null || fail "the generation manifest"

    # The generation's alias applies the instance buffer to a fresh home.
    work=$TMPDIR/herdr-e2e
    mkdir -p "$work/home" "$work/repo"
    cp -R ${buffer} "$work/repo/local-maintained-files"
    chmod -R u+w "$work/repo"
    git -C "$work/repo" init -q -b main
    git -C "$work/repo" add -A
    git -C "$work/repo" -c user.name=check -c user.email=check@example.invalid commit -q -m buffer
    HERDR_CALL_LOG=$work/calls HERDR_SOCKET_PATH=$work/herdr.sock PATH="$gen/home-path/bin:$PATH" \
      local-maintained-files --repo "$work/repo" --home "$work/home" --state-dir "$work/state" apply
    config=$work/home/.config/herdr/config.toml
    [[ -f $config && $(stat -c %a "$config") == 644 ]] || fail "the herdr configuration was not created 0644"
    grep -qx 'onboarding = false' "$config" || fail "onboarding was not written: $(<"$config")"
    grep -qx 'prefix = "ctrl+b"' "$config" || fail "keys.prefix was not written: $(<"$config")"
    printf '%s\n' "herdr server reload-config" \
      "env HOME=$work/home XDG_CONFIG_HOME=$work/home/.config HERDR_SOCKET_PATH=<unset>" >"$work/expected"
    cmp "$work/expected" "$work/calls" || fail "reload calls: $(<"$work/calls")"
  '';
}
