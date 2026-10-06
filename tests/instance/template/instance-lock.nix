# The flake.lock of a fresh template instance, built offline: what
# `nix flake lock` writes for template/flake.nix before `dotsteward init`
# adds component inputs. Used by checks.template-static and by
# tests/instance/template/helpers.sh (write_instance_lock).
#
#   import ./instance-lock.nix { frameworkLock; templateFlake; } -> lock
#
# frameworkLock is the framework flake.lock (parsed) and templateFlake the
# imported template/flake.nix. The template pins nixpkgs and home-manager at
# the framework's revisions (tests/instance/template/test-flake.sh asserts
# it), so their nodes are the framework's. The dotsteward node follows both
# and records the template's github:<owner>/<repo>/<tag> reference; nothing
# fetches it: the pins engine leaves dotsteward out of the flake-input parity
# ([pins] excluded_flake_inputs) and the checks pass the framework under
# test as the dotsteward input.
{
  frameworkLock,
  templateFlake,
}:
let
  inherit (templateFlake) inputs;

  rootInputs = frameworkLock.nodes.${frameworkLock.root}.inputs;
  frameworkNode = name: frameworkLock.nodes.${rootInputs.${name}};

  reference = builtins.match "github:([^/]+)/([^/]+)/([^/]+)" inputs.dotsteward.url;
  github =
    if reference == null then
      throw "instance-lock.nix: the template dotsteward input is not github:<owner>/<repo>/<tag>: ${inputs.dotsteward.url}"
    else
      {
        type = "github";
        owner = builtins.elemAt reference 0;
        repo = builtins.elemAt reference 1;
      };
in
{
  nodes = {
    nixpkgs = frameworkNode "nixpkgs";
    home-manager = frameworkNode "home-manager";
    dotsteward = {
      inputs = {
        nixpkgs = [ "nixpkgs" ];
        home-manager = [ "home-manager" ];
      };
      locked = github // {
        rev = "0000000000000000000000000000000000000000";
      };
      original = github // {
        ref = builtins.elemAt reference 2;
      };
    };
    root.inputs = {
      nixpkgs = "nixpkgs";
      home-manager = "home-manager";
      dotsteward = "dotsteward";
    };
  };
  root = "root";
  version = 7;
}
