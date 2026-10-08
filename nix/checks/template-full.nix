# The full Linux fixture instance (tests/fixtures/instances/full): all six
# catalog components (shell, herdr, claude-code, codex, opencode-pi, vscode)
# and the two synthetic private components example-app and example-term,
# built on x86_64-linux and probed.
#
# The instance is what `dotsteward init` makes of the framework template:
# the files of template/ (the launcher, and bootstrap.sh once the template
# ships it, which `dotsteward static` compares byte for byte) with the
# fixture's files on top, plus the .dotsteward/ mirrors that `dotsteward
# sync` writes, rendered from the evaluated instance so they are always
# current. The herdr flake input is the stand-in package of the herdr
# component tests (an application input is never a framework input).
#
# Built: every check of the instance on x86_64-linux, among them the
# generations of both profiles (which hold the starship package), the Pi
# package, the private example-app package, the manifest checks, the
# instance static scripts and the instance contract (static --sandbox, the
# offline pins check, settings validate, the privacy scan). Then the
# check-profile generation is
# inspected (packages, agent rules, managed links, the default editor, the
# manifest) and its probe registry runs exactly as the gate's cli-probes
# step runs it: `dotsteward --instance ROOT probes --generation GENERATION`.
# Evaluating an instance whose root is a derivation imports from a
# derivation; framework checks are the only place that does that.
{
  self,
  pkgs,
  lib,
  dsLib,
  system,
  ...
}:
let
  cli = dsLib.mkCli pkgs;

  fixture = ../../tests/fixtures/instances/full;

  # The stand-in herdr of the herdr component tests: herdr --version prints
  # "herdr 0.9.3", the version the fixture lock pins.
  inherit (import ../../tests/nix/components/herdr/flake-instance.nix { inherit self dsLib pkgs; })
    herdr
    ;

  instanceAt =
    root:
    dsLib.mkInstance {
      inherit root;
      inputs = {
        self.outPath = root;
        inherit (self.inputs) nixpkgs home-manager;
        dotsteward = self;
        herdr.packages.${system}.herdr = herdr;
      };
    };

  # The template with the fixture on top: what init writes, before sync.
  templateRoot = pkgs.runCommand "dotsteward-full-instance-template" { } ''
    cp -R ${../../template} "$out"
    chmod -R u+w "$out"
    cp -R ${fixture}/. "$out/"
  '';

  # The same instance with its current mirrors.
  root = pkgs.runCommand "dotsteward-full-instance" { } ''
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
  checks = instance.checks.${system};
  generation = checks.home;

  # Every check the instance must define, no more and no less.
  expectedChecks = [
    "dotsteward-manifest"
    "example-app"
    "home"
    "home-fresh"
    "home-workstation"
    "instance-contract"
    "instance-static"
    "manifest-consistent"
    "pi"
  ];
  checkNames = lib.attrNames checks;

  expectedManifest = pkgs.writeText "manifest.json" (
    builtins.toJSON instance.dotstewardManifest.${system}
  );
in
assert lib.assertMsg (checkNames == expectedChecks)
  "template-full: the instance checks are ${toString checkNames}, expected ${toString expectedChecks}";
pkgs.runCommand "dotsteward-check-template-full"
  {
    nativeBuildInputs = cli.toolchain ++ [ cli ];
    # The instance root and outputs, to build one of its checks alone.
    passthru = { inherit root instance; };
  }
  ''
    fail() {
      printf 'template-full: %s\n' "$*" >&2
      exit 1
    }

    # Every check of the instance is built.
    ${lib.concatMapStrings (name: ''
      [[ -e ${checks.${name}} ]] || fail "checks.${system}.${name} was not built"
    '') checkNames}

    gen=${generation}
    [[ -x $gen/activate ]] || fail "$gen is not an activation package"
    [[ -x ${checks.home-fresh}/activate ]] || fail "the fresh generation is not an activation package"

    # The generation ships the evaluated manifest.
    manifest=$gen/home-path/share/dotsteward/manifest.json
    cmp ${expectedManifest} "$manifest" || fail "the generation manifest differs from dotstewardManifest"

    # Nix-installed commands: zsh and starship (shell), herdr (the input's
    # package), pi (opencode-pi) and example-app. The official-binary
    # (claude, codex, opencode, example-term) and deb (code) commands are
    # installed outside Home Manager.
    bin=$gen/home-path/bin
    for command in zsh starship herdr pi example-app; do
      [[ -x $bin/$command ]] || fail "the generation lacks $command"
    done
    for command in claude codex opencode code example-term; do
      [[ ! -e $bin/$command ]] || fail "the generation installs $command, which its method installs outside Nix"
    done
    [[ $(readlink -f "$bin/herdr") == ${herdr}/bin/herdr ]] || fail "herdr is not the herdr input's package"
    [[ $(readlink -f "$bin/starship") == ${instance.packages.${system}.starship}/bin/starship ]] ||
      fail "starship is not packages.${system}.starship"
    [[ $(readlink -f "$bin/pi") == ${instance.packages.${system}.pi}/bin/pi ]] ||
      fail "pi is not packages.${system}.pi"
    [[ $("$bin/example-app") == "example-app 1.2.3" ]] || fail "example-app: $("$bin/example-app")"

    # The components, their resolved methods and the order of [components].
    jq -e '
      [.components[] | {name, method}] == [
        {name: "shell", method: "nix"},
        {name: "herdr", method: "nix"},
        {name: "claude-code", method: "official-binary"},
        {name: "codex", method: "official-binary"},
        {name: "opencode-pi", method: "official-binary"},
        {name: "vscode", method: "deb"},
        {name: "example-app", method: "nix"},
        {name: "example-term", method: "official-binary"}
      ]' "$manifest" >/dev/null || fail "manifest components: $(jq -c '[.components[] | {name, method}]' "$manifest")"
    jq -e '.login_shell == "$HOME/.nix-profile/bin/zsh"' "$manifest" >/dev/null ||
      fail "login shell: $(jq -c .login_shell "$manifest")"

    # One agent rules source behind every agent rules link; every managed
    # link is in the generation.
    files=$gen/home-files
    rules_source=$(cd ${fixture} && realpath home/AGENTS.md)
    for rules in .claude/CLAUDE.md .codex/AGENTS.md .pi/agent/AGENTS.md .example-term/AGENTS.md; do
      cmp "$rules_source" "$files/$rules" || fail "$rules is not home/AGENTS.md"
    done
    mapfile -t links < <(jq -r '.managed_links[]' "$manifest")
    expected_links=(
      "~/.config/nix/nix.conf"
      "~/.zshrc"
      "~/.config/starship.toml"
      "~/.claude/CLAUDE.md"
      "~/.codex/AGENTS.md"
      "~/.pi/agent/AGENTS.md"
      "~/.example-term/AGENTS.md"
    )
    [[ $(printf '%s\n' "''${links[@]}" | LC_ALL=C sort) == $(printf '%s\n' "''${expected_links[@]}" | LC_ALL=C sort) ]] ||
      fail "managed links: ''${links[*]}"
    for link in "''${links[@]}"; do
      [[ -e $files/''${link#"~/"} ]] || fail "managed link $link is not in the generation"
    done
    ${pkgs.zsh}/bin/zsh -n "$files/.zshrc" || fail "~/.zshrc is not valid zsh"
    grep -qx 'add_newline = false' "$files/.config/starship.toml" ||
      fail "starship.toml lacks the instance settings: $(<"$files/.config/starship.toml")"

    # vscode set_default_editor: the editor variables of every profile.
    for vars in "$gen" ${checks.home-fresh}; do
      vars=$vars/home-path/etc/profile.d/hm-session-vars.sh
      grep -qx 'export EDITOR="code"' "$vars" || fail "EDITOR is not code in $vars"
      grep -qx 'export VISUAL="code"' "$vars" || fail "VISUAL is not code in $vars"
      grep -qx 'export GIT_EDITOR="code --wait"' "$vars" || fail "GIT_EDITOR is not code --wait in $vars"
    done

    # example-term reads its options, and its greeting and agent rules link
    # exist only in the profiles it is active in (workstation).
    [[ $(<"$files/.example-term/greeting") == "hello from the full instance" ]] ||
      fail "the example-term greeting: $(<"$files/.example-term/greeting")"
    [[ ! -e ${checks.home-fresh}/home-files/.example-term/greeting ]] ||
      fail "example-term writes its greeting in the fresh profile"
    [[ ! -e ${checks.home-fresh}/home-files/.example-term/AGENTS.md ]] ||
      fail "example-term is active in the fresh profile"
    [[ -e ${checks.home-fresh}/home-files/.claude/CLAUDE.md ]] ||
      fail "claude-code is not active in the fresh profile"

    # The probe registry of the check profile, as the gate runs it.
    export HOME=$TMPDIR/home
    mkdir -p "$HOME"
    dotsteward --instance ${root} probes --generation "$gen" >"$TMPDIR/probes.log" 2>&1 ||
      fail "probes failed: $(<"$TMPDIR/probes.log")"
    cat "$TMPDIR/probes.log"
    grep -qF 'probes passed: 1 version, 2 presence, 2 features (profile workstation)' "$TMPDIR/probes.log" ||
      fail "unexpected probe summary: $(<"$TMPDIR/probes.log")"

    touch "$out"
  ''
