# The template static contract: tests/instance/template in the
# build sandbox (the files of template/, its flake inputs at the framework
# flake.lock revisions and the dotsteward tag at VERSION, the lock files, the
# workstation.toml skeleton, the wrappers, the generated stage-0
# bootstrap.sh, the documents, the example component and the privacy scan;
# the template as an instance passes the instance contract), then every
# check of the template instance itself is built.
#
# The template instance is what `nix flake init -t` leaves after
# `nix flake lock` and `dotsteward sync`: template/ with the flake.lock of
# its inputs (tests/instance/template/instance-lock.nix) and the .dotsteward/
# mirrors rendered from the evaluated instance. Its checks are the
# generations of both profiles, the current mirrors, the consistent
# manifest, the static scripts and the instance contract. Evaluating an
# instance whose root is a derivation imports from a derivation; framework
# checks are the only place that does that.
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

  testEnv = pkgs.writeTextFile {
    name = "dotsteward-template-static-test-env";
    destination = "/nix-support/setup-hook";
    text = ''
      export DS_NIXPKGS=${pkgs.path}
      export DS_HOME_MANAGER=${self.inputs.home-manager}
    '';
  };

  instanceLock = import ../../tests/instance/template/instance-lock.nix {
    frameworkLock = lib.importJSON ../../flake.lock;
    templateFlake = import ../../template/flake.nix;
  };

  instanceAt =
    root:
    dsLib.mkInstance {
      inherit root;
      inputs = {
        self.outPath = root;
        inherit (self.inputs) nixpkgs home-manager;
        dotsteward = self;
      };
    };

  # The template with the lock of its inputs: what init leaves before sync.
  lockedRoot = pkgs.runCommand "dotsteward-template-instance-locked" { } ''
    cp -R ${../../template} "$out"
    chmod -R u+w "$out"
    cp ${pkgs.writeText "flake.lock" (builtins.toJSON instanceLock)} "$out/flake.lock"
  '';

  # withMirrors NAME BASE: the instance BASE plus its current mirrors.
  withMirrors =
    name: base:
    pkgs.runCommand name { } ''
      cp -R ${base} "$out"
      chmod -R u+w "$out"
      mkdir -p "$out/.dotsteward"
      ${lib.concatStrings (
        lib.mapAttrsToList (name: text: ''
          cp ${pkgs.writeText name text} "$out/.dotsteward/${name}"
        '') (instanceAt "${base}").dotstewardMirrors
      )}
    '';

  root = withMirrors "dotsteward-template-instance" lockedRoot;
  instance = instanceAt "${root}";
  checks = instance.checks.${system};

  # The template instance with the example static script of
  # template/tests/README.md as its [gate] static script: instance-static
  # runs it with the environment the README documents.
  scriptedBase = pkgs.runCommand "dotsteward-template-instance-scripted-base" { } ''
    cp -R ${lockedRoot} "$out"
    chmod -R u+w "$out"
    bash ${../../tests/instance/template/readme-example.sh} ${../../template/tests/README.md} \
      "$out/tests/static.sh"
    printf '\n[gate]\nstatic = ["tests/static.sh"]\n' >>"$out/workstation.toml"
  '';
  scriptedRoot = withMirrors "dotsteward-template-instance-scripted" scriptedBase;
  scripted = (instanceAt "${scriptedRoot}").checks.${system};

  # Every check the template instance must define, no more and no less.
  expectedChecks = [
    "dotsteward-manifest"
    "home"
    "home-fresh"
    "home-workstation"
    "instance-contract"
    "instance-static"
    "manifest-consistent"
  ];
  checkNames = lib.attrNames checks;
in
assert lib.assertMsg (checkNames == expectedChecks)
  "template-static: the template instance checks are ${toString checkNames}, expected ${toString expectedChecks}";
cli.mkTestCheck {
  name = "template-static";
  paths = [ "tests/instance/template" ];
  # template/bootstrap.sh is compared with the generated stage-0 byte for
  # byte; the wrappers and the launcher run in the sandbox, so their
  # shebangs are patched.
  keepShebangs = [ "template/bootstrap.sh" ];
  nativeBuildInputs = [
    pkgs.nix
    pkgs.shellcheck
    testEnv
  ];
  postCheck = ''
    fail() {
      printf 'template-static: %s\n' "$*" >&2
      exit 1
    }
    # template/bootstrap.sh is the generated stage-0, as committed.
    bash ${self}/tools/gen-stage0.sh --check --root ${self} ||
      fail "template/bootstrap.sh is not the generated stage-0"

    # Every check of the template instance is built; both generations are
    # activation packages.
    ${lib.concatMapStrings (name: ''
      [[ -e ${checks.${name}} ]] || fail "checks.${system}.${name} of the template instance was not built"
    '') checkNames}
    for generation in ${checks.home} ${checks.home-fresh}; do
      [[ -x $generation/activate ]] || fail "$generation is not an activation package"
    done
    jq -e '.components == []' ${checks.home}/home-path/share/dotsteward/manifest.json >/dev/null ||
      fail "the template generation lists components"

    # The README example runs as an instance static script in the sandbox.
    [[ -e ${scripted.instance-static} && -e ${scripted.instance-contract} ]] ||
      fail "the README static script example did not pass"
  '';
}
