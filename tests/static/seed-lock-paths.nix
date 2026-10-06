# Lock paths of the catalog components and the seeds that provide them
# (SPEC 5.6): every versions.lock.json path a catalog component reads exists
# in the versions_lock of its modules/components/<name>/seed.json or in
# template/versions.lock.json, when the framework ships one. Evaluated by
# tests/static/test-seeds.sh:
#
#   nix-instantiate --eval --strict --json seed-lock-paths.nix \
#     --argstr nixpkgs PATH --argstr homeManager PATH --argstr repo FRAMEWORK
#     -> sorted list of "<name>/seed.json: lock path <path> read by <reader> is missing"
#
# The catalog of the framework source FRAMEWORK is evaluated the way
# lib.mkInstance evaluates it (the Home Manager configuration of
# tests/nix/core/prelude.nix: modules/core, the mkInstance module arguments),
# every component enabled, on x86_64-linux and aarch64-darwin. mkInstance's
# own guards (supported platforms and methods) are left out: they depend on
# what an instance configures, not on the seed. A missing seed.json is the
# schema half's finding (`dotsteward static --only seeds`) and counts as an
# empty versions_lock here; invalid JSON fails the evaluation.
#
# The lock paths a component reads (readers):
#   install.<method>.pin of official-binary, deb and app-archive, and
#     install.external.minimum, for every method of supportedMethods (linux
#     and darwin), since each of them can become the resolved method; the
#     nullable ones only when set
#   probe <command>: expected with the versions: prefix
#   floor <command>: minimum when it is a lock path, that is at least two
#     dot-separated segments and not a version (a version starts with a
#     digit, or with v and a digit)
#   pins.flakeInputs: flake_inputs.<name>
#   pins.rules <kind>.<field>: the fields at, to, from and every *_at field,
#     a string or a list of strings; a value with a { placeholder is a
#     template the pins engine expands (for_each) and is not checked here
{
  nixpkgs,
  homeManager,
  repo,
}:
let
  inherit (builtins)
    attrNames
    elem
    fromJSON
    isList
    isString
    match
    pathExists
    readFile
    ;

  scope = import (/. + repo + "/tests/nix/core/prelude.nix") { inherit nixpkgs homeManager repo; };
  inherit (scope) lib dsLib;

  framework = /. + repo;
  componentsDir = framework + "/modules/components";
  names = attrNames dsLib.catalog;

  systems = [
    "x86_64-linux"
    "aarch64-darwin"
  ];

  cfg = dsLib.config.resolve { catalog = names; } {
    schema_version = 1;
    identity.username = "alice";
    instance.remote = "git@github.com:alice/workstation.git";
    nix = {
      inherit systems;
      state_version = "25.11";
    };
    profiles.names = [ "workstation" ];
    components = lib.genAttrs names (_: {
      enable = true;
    });
  };

  # dotsteward.components of every system, as mkInstance's mkHome sets it
  # up for an instance that enables the whole catalog.
  configs = map (
    system:
    (scope.homeOf {
      config = cfg;
      inherit system;
      modules = map (name: dsLib.catalog.${name} + "/default.nix") names ++ [
        {
          dotsteward.components = lib.genAttrs names (_: {
            enable = true;
          });
        }
      ];
    }).dotsteward.components
  ) systems;

  readJSON = file: if pathExists file then fromJSON (readFile file) else { };

  templateLock = readJSON (framework + "/template/versions.lock.json");

  isVersion = value: match "v?[0-9].*" value != null;
  isLockPath =
    value:
    match "[A-Za-z0-9_][A-Za-z0-9_+-]*(\\.[A-Za-z0-9_][A-Za-z0-9_+-]*)+" value != null
    && !isVersion value;

  read = reader: path: { inherit reader path; };

  # Install block field holding a lock path, per method.
  installFields = {
    official-binary = "pin";
    deb = "pin";
    app-archive = "pin";
    external = "minimum";
  };

  installReads =
    component:
    lib.concatMap (
      method:
      let
        field = installFields.${method};
        value = component.install.${method}.${field};
      in
      lib.optional (installFields ? ${method} && value != null) (read "install.${method}.${field}" value)
    ) (lib.unique (component.supportedMethods.linux ++ component.supportedMethods.darwin));

  probeReads =
    component:
    lib.concatMap (
      probe:
      lib.optional (probe.expected != null && lib.hasPrefix "versions:" probe.expected) (
        read "probe ${probe.command}" (lib.removePrefix "versions:" probe.expected)
      )
    ) component.probes;

  floorReads =
    component:
    lib.concatMap (
      floor: lib.optional (isLockPath floor.minimum) (read "floor ${floor.command}" floor.minimum)
    ) component.checks.floors;

  flakeInputReads =
    component: map (name: read "pins.flakeInputs" "flake_inputs.${name}") component.pins.flakeInputs;

  isRuleField =
    field:
    elem field [
      "at"
      "to"
      "from"
    ]
    || lib.hasSuffix "_at" field;

  ruleReads =
    component:
    lib.concatMap (
      rule:
      lib.concatMap (
        field:
        let
          value = rule.${field};
          values =
            if isString value then
              [ value ]
            else if isList value then
              lib.filter isString value
            else
              [ ];
        in
        map (read "pins.rules ${rule.kind}.${field}") (lib.filter (path: !lib.hasInfix "{" path) values)
      ) (lib.filter isRuleField (attrNames rule))
    ) component.pins.rules;

  readsOf =
    component:
    installReads component
    ++ probeReads component
    ++ floorReads component
    ++ flakeInputReads component
    ++ ruleReads component;

  problemsOf =
    name:
    let
      seed = readJSON (componentsDir + "/${name}/seed.json");
      lock = lib.recursiveUpdate templateLock (seed.versions_lock or { });
      reads = lib.unique (
        lib.concatMap (
          components: lib.optionals (components ? ${name}) (readsOf components.${name})
        ) configs
      );
    in
    map (entry: "${name}/seed.json: lock path ${entry.path} read by ${entry.reader} is missing") (
      lib.filter (entry: !lib.hasAttrByPath (lib.splitString "." entry.path) lock) reads
    );
in
lib.sort lib.lessThan (lib.unique (lib.concatMap problemsOf names))
