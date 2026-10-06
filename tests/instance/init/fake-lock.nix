# The flake.lock the fake nix of the init tests (fake-nix.sh) writes for
# `nix flake lock` of an instance, offline:
#
#   import ./fake-lock.nix { frameworkLock; flake; versionsLock; } -> lock
#
# frameworkLock is the framework flake.lock (parsed), flake the imported
# instance flake.nix and versionsLock its versions.lock.json (parsed).
# nixpkgs and home-manager are the framework's nodes (the template pins them
# at the framework revisions). Every other github input is locked at the
# revision and narHash its versions.lock.json flake_inputs entry records,
# which is what Nix resolves for a component input whose seed the release
# CI proved; an input without such an entry is an error, except dotsteward,
# which no rule reads (the pins engine leaves it out of the parity check)
# and which is locked at a zero revision. path: and git+file: references
# (--framework-url) are locked without fetching.
{
  frameworkLock,
  flake,
  versionsLock,
}:
let
  rootInputs = frameworkLock.nodes.${frameworkLock.root}.inputs;
  frameworkNode = name: frameworkLock.nodes.${rootInputs.${name}};

  zeroRevision = "0000000000000000000000000000000000000000";
  zeroNarHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  pins = versionsLock.flake_inputs or { };

  parse =
    name: url:
    let
      github = builtins.match "github:([^/]+)/([^/]+)/([^/?]+)([?].*)?" url;
      path = builtins.match "path:([^?]+)([?].*)?" url;
      git = builtins.match "git[+](file://[^?]+)([?].*)?" url;
    in
    if github != null then
      {
        kind = "github";
        owner = builtins.elemAt github 0;
        repo = builtins.elemAt github 1;
        ref = builtins.elemAt github 2;
      }
    else if path != null then
      {
        kind = "path";
        path = builtins.elemAt path 0;
      }
    else if git != null then
      {
        kind = "git";
        url = builtins.elemAt git 0;
      }
    else
      throw "fake nix: unsupported flake reference of input ${name}: ${url}";

  sourceNode =
    name: url:
    let
      reference = parse name url;
      github = {
        type = "github";
        inherit (reference) owner repo;
      };
      pin =
        if pins ? ${name} then
          pins.${name}
        else if name == "dotsteward" then
          { revision = zeroRevision; }
        else
          throw "fake nix: versions.lock.json has no flake_inputs entry for input ${name}";
    in
    if reference.kind == "github" then
      {
        locked =
          github
          // {
            rev = pin.revision;
          }
          // (if pin ? nar_hash then { narHash = pin.nar_hash; } else { });
        original = github // {
          inherit (reference) ref;
        };
      }
    else if reference.kind == "path" then
      {
        locked = {
          type = "path";
          inherit (reference) path;
          narHash = zeroNarHash;
        };
        original = {
          type = "path";
          inherit (reference) path;
        };
      }
    else
      {
        locked = {
          type = "git";
          inherit (reference) url;
          rev = zeroRevision;
        };
        original = {
          type = "git";
          inherit (reference) url;
        };
      };

  nodeFor =
    name: input:
    if name == "nixpkgs" || name == "home-manager" then
      frameworkNode name
    else
      sourceNode name input.url
      // (
        if input ? inputs then
          { inputs = builtins.mapAttrs (_: follower: [ follower.follows ]) input.inputs; }
        else
          { }
      )
      // (if (input.flake or true) then { } else { flake = false; });
in
{
  nodes = builtins.mapAttrs nodeFor flake.inputs // {
    root.inputs = builtins.mapAttrs (name: _: name) flake.inputs;
  };
  root = "root";
  version = 7;
}
