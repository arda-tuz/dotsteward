# The shell catalog component (tests/nix/components/shell): the byte-exact
# .zshrc blocks and their options, the starship package and settings, the
# contract values with their reflection in the manifest and pinned versions,
# the seed and the documentation. The tests evaluate instances with
# nix-instantiate against an isolated store, so the sandbox needs Nix and the
# nixpkgs and home-manager sources; a setup hook exports their paths.
#
# Then the fixture instance is built inside this flake: the generation links
# the expected ~/.zshrc and starship.toml, installs zsh and the pinned
# starship, and an interactive zsh started with that ~/.zshrc in a scratch
# home loads both plugins and the starship prompt.
{
  self,
  pkgs,
  dsLib,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  jsonschemaPython = pkgs.python3.withPackages (ps: [ ps.jsonschema ]);

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-component-shell-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
      export DS_JSONSCHEMA_PYTHON=${jsonschemaPython.interpreter}
    '';
  };

  fixtures = ../../tests/nix/components/shell/fixtures;
  instance = import ../../tests/nix/components/shell/flake-instance.nix { inherit self dsLib; };
  generation = instance.checks.x86_64-linux.home;

  # fixtures/instance.zshrc with the plugin store paths of the locked nixpkgs.
  expectedZshrc = pkgs.writeText "expected.zshrc" (
    builtins.replaceStrings
      [ "@AUTOSUGGESTIONS@" "@SYNTAX_HIGHLIGHTING@" ]
      [ "${pkgs.zsh-autosuggestions}" "${pkgs.zsh-syntax-highlighting}" ]
      (builtins.readFile (fixtures + "/instance.zshrc"))
  );
in
cli.mkTestCheck {
  name = "component-shell";
  paths = [ "tests/nix/components/shell" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
    testEnv
  ];
  postCheck = ''
    fail() {
      printf 'component-shell: %s\n' "$*" >&2
      exit 1
    }
    shellcheck -x tests/nix/components/shell/*.sh

    gen=${generation}
    [[ -x $gen/activate ]] || fail "$gen is not an activation package"

    # The linked files: ~/.zshrc byte for byte, starship.toml by value.
    cmp ${expectedZshrc} "$gen/home-files/.zshrc" ||
      fail "~/.zshrc differs: $(diff ${expectedZshrc} "$gen/home-files/.zshrc" || true)"
    ${pkgs.zsh}/bin/zsh -n "$gen/home-files/.zshrc" || fail "~/.zshrc is not valid zsh"
    python3 - "$gen/home-files/.config/starship.toml" ${fixtures}/starship.toml <<'PY' ||
    import sys
    import tomllib

    with open(sys.argv[1], "rb") as linked, open(sys.argv[2], "rb") as expected:
        sys.exit(0 if tomllib.load(linked) == tomllib.load(expected) else 1)
    PY
      fail "starship.toml differs: $(<"$gen/home-files/.config/starship.toml")"

    # The packages: zsh of the locked nixpkgs and the pinned starship.
    [[ $(readlink -f "$gen/home-path/bin/zsh") == "$(readlink -f ${pkgs.zsh}/bin/zsh)" ]] ||
      fail "home-path/bin/zsh is not the zsh of the locked nixpkgs"
    [[ $(readlink -f "$gen/home-path/bin/starship") == ${instance.packages.x86_64-linux.starship}/bin/starship ]] ||
      fail "home-path/bin/starship is not packages.x86_64-linux.starship"
    version=$(HOME=$TMPDIR "$gen/home-path/bin/starship" --version | head -n 1)
    [[ $version == "starship 1.26.0" ]] || fail "starship --version: $version"
    jq -e '.login_shell == "$HOME/.nix-profile/bin/zsh" and .pinned_versions.starship == "1.26.0"' \
      "$gen/home-path/share/dotsteward/manifest.json" >/dev/null || fail "the generation manifest"

    # An interactive zsh with the linked ~/.zshrc loads both plugins and the
    # starship prompt; a dumb terminal gets no prompt.
    work=$TMPDIR/shell-e2e
    mkdir -p "$work/home/.local/bin" "$work/home/.config"
    cp "$gen/home-files/.zshrc" "$work/home/.zshrc"
    cp "$gen/home-files/.config/starship.toml" "$work/home/.config/starship.toml"
    probe='print -r -- "''${STARSHIP_SHELL:-none}|''${+functions[_zsh_autosuggest_start]}|''${+functions[_zsh_highlight]}|''${path[(Ie)$HOME/.local/bin]}"'
    run_zsh() {
      env -i HOME="$work/home" TERM="$1" PATH="$gen/home-path/bin:${pkgs.coreutils}/bin" \
        "$gen/home-path/bin/zsh" -i -c "$probe" </dev/null 2>"$work/stderr"
    }
    result=$(run_zsh xterm-256color) || fail "interactive zsh failed: $(<"$work/stderr")"
    [[ $result == "zsh|1|1|"[1-9]* ]] || fail "interactive zsh: $result; stderr: $(<"$work/stderr")"
    [[ ! -s $work/stderr ]] || fail "interactive zsh wrote to stderr: $(<"$work/stderr")"
    result=$(run_zsh dumb) || fail "interactive zsh on a dumb terminal failed: $(<"$work/stderr")"
    [[ $result == "none|1|1|"[1-9]* ]] || fail "dumb terminal: $result"
  '';
}
