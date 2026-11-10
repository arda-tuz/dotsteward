# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# E19: machines and tags reach Nix. A component for some machines is active there and
# nowhere else, the manifest stays one per system, hostConfigurations has every machine, and
# checks.<system>.hosts-eval evaluates each distinct tag set of the system without a build.
# shellcheck source=tests/nix/instance/helpers.sh
source "$DS_REPO_ROOT/tests/nix/instance/helpers.sh"

root=$DS_TEST_ROOT/instance
cp -R "$nix_instance_fixtures/example" "$root"
chmod -R u+w "$root"
mkdir "$root/hosts"
cat >"$root/hosts/laptop.toml" <<'TOML'
schema_version = 1
system = "x86_64-linux"
profile = "workstation"
tags = ["nvidia"]
TOML
cat >"$root/hosts/desktop.toml" <<'TOML'
schema_version = 1
system = "x86_64-linux"
profile = "workstation"
tags = ["nvidia"]
declined = { components = ["example-term"] }
TOML
cat >"$root/hosts/laptop3.toml" <<'TOML'
schema_version = 1
system = "x86_64-linux"
profile = "workstation"
tags = ["nvidia"]
declined = { components = ["example-term"] }
TOML
cat >"$root/hosts/server.toml" <<'TOML'
schema_version = 1
system = "x86_64-linux"
profile = "workstation"
TOML
cat >"$root/hosts/server2.toml" <<'TOML'
schema_version = 1
system = "x86_64-linux"
profile = "workstation"
TOML
cat >"$root/hosts/mac.toml" <<'TOML'
schema_version = 1
system = "aarch64-darwin"
profile = "fresh"
TOML
sed -i 's/^\[components.example-app\]$/[components.example-app]\nmachines = ["laptop", "laptop3"]/' "$root/workstation.toml"
sed -i 's/^\[components.example-term\]$/[components.example-term]\ntags = ["nvidia"]/' "$root/workstation.toml"

hosted="instance { root = /. + \"$root\"; }"

assert_inst_eq '["desktop","laptop","laptop3","mac","server","server2"]' "builtins.attrNames ($hosted).hostConfigurations" "every machine"

# What is active on each: in home.packages (nix) and in the agent rules (official-binary).
active() {
  inst_json "let c = ($hosted).hostConfigurations.$1.config; in {
    app = builtins.any (package: lib.hasPrefix \"example-app\" (package.name or \"\")) c.home.packages;
    term = c.home.file ? \".example-term/AGENTS.md\";
  }" | jq -c '{app, term}'
}
assert_eq '{"app":true,"term":true}' "$(active laptop)" "the machine of the component, a tag it asks for"
assert_eq '{"app":false,"term":false}' "$(active desktop)" "another machine; declined over the tag"
assert_eq '{"app":false,"term":false}' "$(active server)" "another machine, no tag"

# mkHome takes the tags itself; without tags nothing is scoped in.
assert_inst_eq '{"none":false,"tagged":true,"no":false}' "let
    home = tags: (($hosted).lib.mkHome { username = \"alice\"; homeDirectory = \"/home/alice\"; inherit tags; }).config;
    term = tags: (home tags).home.file ? \".example-term/AGENTS.md\";
  in { none = term [ ]; tagged = term [ \"nvidia\" ]; no = term [ \"nvidia\" \"no:example-term\" ]; }" "mkHome tags"

# The tags are there for the module of an instance.
assert_inst_eq '["machine:laptop","nvidia"]' "lib.sort lib.lessThan (instance {
    root = /. + \"$root\";
    homeModules = [ ({ dotsteward, lib, ... }: { options.seen = lib.mkOption { default = dotsteward.tags; }; }) ];
  }).hostConfigurations.laptop.config.seen" "dotsteward.tags"

# One manifest per system, whatever the tags: machines and tags are data in it.
assert_inst_eq '{"same":true,"name":"manifest-consistent"}' "let
    inst = $hosted;
    manifest = name: storeless inst.hostConfigurations.\${name}.config.dotsteward.manifest;
  in {
    same = manifest \"laptop\" == manifest \"desktop\" && manifest \"laptop\" == manifest \"server\"
      && manifest \"laptop\" == storeless inst.dotstewardManifest.x86_64-linux;
    name = inst.checks.x86_64-linux.manifest-consistent.name;
  }" "the manifest does not depend on the tags"
assert_inst_eq '{"machines":["laptop","laptop3"],"tags":null}' "let
    entry = lib.findFirst (c: c.name == \"example-app\") null ($hosted).dotstewardManifest.x86_64-linux.components;
  in { inherit (entry) machines; tags = entry.tags or null; }" "a scope is data"
assert_inst_eq '{"has":false}' 'let
    entry = lib.findFirst (c: c.name == "example-app") null example.dotstewardManifest.x86_64-linux.components;
  in { has = entry ? machines || entry ? tags; }' "no scope, no key: the mirror of an instance keeps its bytes"
violation="instance { root = /. + \"$root\"; homeModules = [ ({ lib, dotsteward, ... }: {
  dotsteward.components.example-app.checks.commands = lib.mkIf (lib.elem \"nvidia\" dotsteward.tags) [ \"tagged-only\" ];
}) ]; }"
assert_inst_fails "($violation).checks.x86_64-linux.manifest-consistent.drvPath" \
  "dotsteward: the manifest of machine" "differs from the manifest of profile workstation" "(keys: checks)"

# hosts-eval: each distinct tag set once, the machines of the system only, without a build.
assert_inst_eq '{"linux":["desktop","laptop","laptop3","server"],"darwin":["mac"],"context":1}' "let
    inst = $hosted;
    check = system: inst.checks.\${system}.hosts-eval;
  in {
    linux = lib.sort lib.lessThan (check \"x86_64-linux\").passthru.evaluated;
    darwin = (check \"aarch64-darwin\").passthru.evaluated;
    context = builtins.length (builtins.attrNames (builtins.getContext (check \"x86_64-linux\").drvPath));
  }" "each distinct tag set"
assert_inst_eq '[]' 'example.checks.x86_64-linux.hosts-eval.passthru.evaluated' "an instance without hosts"

# `requires` is a statement about the machine it concerns: no machine's gate fails for another
# machine's answer. It is data in the manifest, which the CLI of that machine reads.
requiring="instance { root = /. + \"$root\"; homeModules = [ ({ ... }: {
  dotsteward.components.example-app.requires = [ \"example-term\" ];
}) ]; }"
assert_inst_eq 'true' "builtins.isString ($requiring).checks.x86_64-linux.hosts-eval.drvPath" \
  "laptop3 leaves out what example-app needs: no failure of the gate"
assert_inst_eq '["example-term"]' "let
    entry = lib.findFirst (c: c.name == \"example-app\") null ($requiring).dotstewardManifest.x86_64-linux.components;
  in entry.requires" "a requirement is data"
assert_inst_eq '{"has":false}' 'let
    entry = lib.findFirst (c: c.name == "example-app") null example.dotstewardManifest.x86_64-linux.components;
  in { has = entry ? requires; }' "no requirement, no key"

# Any other assertion of one machine stops the gate, and names the machine it is about.
failing="instance { root = /. + \"$root\"; homeModules = [ ({ lib, dotsteward, ... }: {
  assertions = [ { assertion = !(lib.elem \"no:example-term\" dotsteward.tags); message = \"example-home needs example-term\"; } ];
}) ]; }"
assert_inst_fails "($failing).checks.x86_64-linux.hosts-eval.drvPath" \
  "dotsteward: machine laptop3 does not evaluate with hosts/laptop3.toml:" "example-home needs example-term"

# Links are data of their component, and the generation says which targets are active.
assert_inst_eq '["~/.example-term/AGENTS.md"]' "($hosted).dotstewardManifest.x86_64-linux.component_managed_links.example-term" \
  "the links of a component"
assert_inst_eq '{"desktop":false,"laptop":true}' "let
    active = name: (($hosted).hostConfigurations.\${name}.config.dotsteward.cli.settingsTargets).example-term.active;
  in { desktop = active \"desktop\"; laptop = active \"laptop\"; }" "active targets of a machine"

# What mkInstance refuses.
bad=$DS_TEST_ROOT/bad
cp -R "$root" "$bad"
sed -i 's/^machines = \["laptop", "laptop3"\]$/machines = ["ghost"]/' "$bad/workstation.toml"
assert_inst_fails "(instance { root = /. + \"$bad\"; }).checks.x86_64-linux.home.drvPath" \
  'dotsteward: component example-app: machines names ghost, which has no hosts/ghost.toml'
sed -i 's/^machines = \["ghost"\]$/machines = []/' "$bad/workstation.toml"
assert_inst_fails "(instance { root = /. + \"$bad\"; }).checks.x86_64-linux.home.drvPath" 'machines'
sed -i 's/^machines = \[\]$/machines = ["laptop"]/; s/^tags = \["nvidia"\]$/tags = ["machine:laptop"]/' "$bad/workstation.toml"
assert_inst_fails "(instance { root = /. + \"$bad\"; }).checks.x86_64-linux.home.drvPath" 'tags'

# An older framework has no tags: the host flake only passes what mkHome takes.
assert_inst_eq '{"now":true,"old":{"homeDirectory":"/h","profile":"p","username":"u"}}' '{
    now = (builtins.functionArgs example.lib.mkHome) ? tags;
    old = builtins.intersectAttrs (builtins.functionArgs ({ username, homeDirectory, profile ? "x", system ? "y" }: { }))
      { username = "u"; homeDirectory = "/h"; profile = "p"; tags = [ "machine:laptop" ]; };
  }' "functionArgs"

# The platform layer reaches the configuration of a machine through the release its host file
# names: a component that platforms/ calls unavailable there is left out of it (a no: tag), so
# gate builds the generation that rebuild activates. A machine of another release keeps it.
plat=$DS_TEST_ROOT/platform-instance
cp -R "$root" "$plat"
mkdir -p "$plat/platforms"
printf 'schema_version = 1\n[components.example-term]\nunavailable = "not on this release"\n' >"$plat/platforms/ubuntu.toml"
printf 'platform = "ubuntu-22.04"\n' >>"$plat/hosts/laptop.toml"
printf 'platform = "debian-12"\n' >>"$plat/hosts/server.toml"
assert_inst_eq '{"laptop":true,"server":false}' "let
    i = instance { root = /. + \"$plat\"; homeModules = [ ({ dotsteward, lib, ... }: { options.seen = lib.mkOption { default = dotsteward.tags; }; }) ]; };
    no = n: lib.elem \"no:example-term\" i.hostConfigurations.\${n}.config.seen;
  in { laptop = no \"laptop\"; server = no \"server\"; }" "the platform of a host file"
