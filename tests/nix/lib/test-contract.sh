# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# lib/contract.nix: the dotsteward.components.<name> option types.
# shellcheck source=tests/nix/lib/helpers.sh
source "$DS_REPO_ROOT/tests/nix/lib/helpers.sh"

assert_nix_eq '["nix","official-binary","deb","app-archive","external"]' 'dsLib.contract.methods'
assert_nix_eq '["deb","app-archive"]' 'dsLib.contract.systemMethods'
assert_nix_eq '["linux","darwin"]' 'dsLib.contract.platforms'
assert_nix_eq '["early","main","late"]' 'dsLib.contract.hookPhases'
assert_nix_eq '["flake-inputs","nix-package-format","derive","download-pin","text-guard","no-literal","npm-bundle","skills-lock-mirror","minimum-version","asset-digest","nix-resolved","skill-digests"]' \
  'dsLib.contract.ruleKinds'
assert_nix_eq '["github-release","npm","apt-index","deb-url","official-manifest","nix-release","channel-head","git-compare","skill-source","local-apt","manual","follows","framework"]' \
  'dsLib.contract.latestAdapters'

# Defaults of a component that declares only its method.
minimal='(evalComponents [ { dotsteward.components.example-app.method = "nix"; } ]).example-app'
assert_nix_eq '{
  "enable": false, "profiles": null, "platforms": ["linux","darwin"], "method": "nix",
  "supportedMethods": {"linux": [], "darwin": []}, "options": {},
  "nix": {"packages": []},
  "deb": {"pin": null, "architecture": null, "verifyAfterInstall": true, "apt": []},
  "appArchiveDest": "~/Applications",
  "external": {"command": null, "versionArgv": null, "minimum": null},
  "pins": {"rules": [], "latest": [], "resolvedVersions": {}, "flakeInputs": []},
  "settingsTargets": {}, "reloadHooks": {}, "probes": [],
  "checks": {"commands": [], "e2e": [], "agents": [], "floors": []},
  "hooks": {"preActivate": [], "systemInstall": [], "postInstall": [], "forbid": [], "agentsInstall": [], "agentsMigrate": [], "agentsPost": [], "desktopApply": []},
  "bootstrap": {"backupPaths": [], "snapshots": [], "prerequisites": {"apt": []}},
  "rebuild": {"adoptPaths": []},
  "rollback": {"managedLinks": [], "forceLinkedRestore": []},
  "preflight": {"detectors": {}},
  "skillLayout": {"legacyRoots": [], "linkRoots": {}, "excludedSubtrees": []},
  "agentRulesTargets": [], "gate": {"updatePaths": []}, "docs": null
}' "let c = $minimal; in {
  inherit (c) enable profiles platforms method supportedMethods options pins settingsTargets reloadHooks probes checks hooks bootstrap rebuild rollback preflight skillLayout agentRulesTargets gate docs;
  nix = c.install.nix;
  deb = { inherit (c.install.deb) pin architecture verifyAfterInstall apt; };
  appArchiveDest = c.install.app-archive.dest;
  external = c.install.external;
}"

# Every field set: values come through, nested defaults apply.
full='(evalComponents [ (import (fixtures + "/component-full.nix")) ]).example-term'
actual=$(nix_lib_json "let c = $full; hookName = h: { inherit (h) name phase profiles; script = baseNameOf h.script; }; in {
  inherit (c) enable profiles platforms method options pins reloadHooks probes agentRulesTargets;
  official = c.install.official-binary;
  deb = c.install.deb;
  app = c.install.app-archive;
  targets = c.settingsTargets;
  e2e = map hookName c.checks.e2e;
  agents = map hookName c.checks.agents;
  floors = c.checks.floors;
  pre = map hookName c.hooks.preActivate;
  snapshots = c.bootstrap.snapshots;
  restore = c.rollback.forceLinkedRestore;
  detectors = c.preflight.detectors;
  links = c.skillLayout.linkRoots;
  docs = baseNameOf c.docs;
}")
check() { assert_eq "$1" "$(jq -cS "$2" <<<"$actual")" "$2"; }
check '["main"]' .profiles
check '["linux"]' .platforms
check '"official-binary"' .method
check '{"flag":true}' .options
check '{"darwin":"example-term-{version}-aarch64-darwin.tar.gz","linux":"example-term-{version}-x86_64-linux.tar.gz"}' .official.asset
check '"at-least"' .official.policy
check '["example-term","example-term-bin"]' .deb.packageNames
check 'true' .deb.verifyAfterInstall
check '{"appName":"Example Term.app","dest":"~/Applications","pin":"desktop_packages.example-term-darwin"}' .app
check '[{"from":"agent_tools.example-term.version","kind":"derive","to":"nix_packages.example-term.expected"}]' .pins.rules
check '[{"adapter":"github-release","id":"agent_tools.example-term","repo":"example/example-term"}]' .pins.latest
check '{"backup":true,"createIfMissing":true,"createMode":"0644","format":"json","path":"~/.config/example-term/alpha.json","reload":"example-term-reload"}' .targets.alpha
check '{"darwin":"~/Library/Application Support/Example Term/delta.json","linux":"~/.config/Example Term/delta.json"}' .targets.delta.path
check '{"command":["example-term","reload"],"env":{},"onFailure":"warn","onSuccess":"silent","requireCommand":null,"timeout":5,"unsetEnv":[]}' .targets.delta.reload
check '{"command":["example-term","server","reload-config"],"env":{"HOME":"{home}"},"onFailure":"silent","onSuccess":"log","requireCommand":"example-term","timeout":15,"unsetEnv":["EXAMPLE_TERM_SOCKET"]}' '.reloadHooks["example-term-reload"]'
check '{"argv":["--version"],"command":"example-term","env":{},"expected":"versions:agent_tools.example-term.version","extract":"prefix:example-term ","kind":"version","needles":[],"profiles":null}' '.probes[0]'
check '{"argv":["--help"],"command":"example-term","env":{"EXAMPLE_TERM_OFFLINE":"1"},"expected":null,"extract":"first-line","kind":"features","needles":["--offline"],"profiles":null}' '.probes[1]'
check '[{"name":"example-term-config","phase":"late","profiles":["main"],"script":"hook.sh"}]' .e2e
check '[{"name":"example-term-agents","phase":"main","profiles":null,"script":"hook.sh"}]' .agents
check '[{"argv":["--version"],"command":"example-term","compare":"semver","minimum":"agent_tools.example-term.minimum"}]' .floors
check '[{"argv":["example-term","dump"],"name":"example-term-state","requireCommand":null}]' .snapshots
check '[{"mode":"0664","path":"~/.config/example-term/rules.md"}]' .restore
check '{"example_detector":{"argv":["example-term","detect"],"matchLine":"yes"}}' .detectors
check '{"~/.example-term/linked":{"targetPrefix":"../../.agents/skills/"}}' .links
check '[{"force":false,"path":".example-term/AGENTS.md"},{"force":true,"path":".example-term/RULES.md"}]' .agentRulesTargets
check '"hook.sh"' .docs

# The method has no default: mkInstance or the component must set it.
assert_nix_fails '(evalComponents [ { dotsteward.components.example-app.enable = true; } ]).example-app.method' \
  "dotsteward.components.example-app.method"

# Type errors name the option.
bad() {
  assert_nix_fails "(evalComponents [ { dotsteward.components.example-app = { method = \"nix\"; } // ($1); } ]).example-app.$2" "$3"
}
bad '{ method = "apt"; }' method "dotsteward.components.example-app.method"
bad '{ enabel = true; }' enable "dotsteward.components.example-app.enabel' does not exist"
bad '{ platforms = [ "windows" ]; }' platforms "dotsteward.components.example-app.platforms"
bad '{ supportedMethods.linux = [ "snap" ]; }' supportedMethods "dotsteward.components.example-app.supportedMethods.linux"
bad '{ install.official-binary.pin = "not a lock path"; }' install.official-binary.pin "dotsteward.components.example-app.install.official-binary.pin"
bad '{ install.official-binary.policy = "newest"; }' install.official-binary.policy "dotsteward.components.example-app.install.official-binary.policy"
bad '{ install.official-binary.dest = "/usr/bin/example-app"; }' install.official-binary.dest "dotsteward.components.example-app.install.official-binary.dest"
bad '{ settingsTargets.alpha = { path = "relative/alpha.json"; format = "json"; createIfMissing = true; }; }' settingsTargets.alpha.path \
  "dotsteward.components.example-app.settingsTargets.alpha.path"
bad '{ settingsTargets.alpha = { path = "~/alpha.yaml"; format = "yaml"; createIfMissing = true; }; }' settingsTargets.alpha.format \
  "dotsteward.components.example-app.settingsTargets.alpha.format"
bad '{ settingsTargets.alpha = { path = { linux = "~/a"; windows = "~/b"; }; format = "json"; createIfMissing = true; }; }' settingsTargets.alpha.path \
  "dotsteward.components.example-app.settingsTargets.alpha.path"
bad '{ settingsTargets.alpha = { path = "~/a.json"; format = "json"; createIfMissing = true; createMode = "644"; }; }' settingsTargets.alpha.createMode \
  "dotsteward.components.example-app.settingsTargets.alpha.createMode"
bad '{ probes = [ { command = "example-app"; kind = "speed"; } ]; }' probes "kind"
bad '{ probes = [ { command = "example-app"; kind = "version"; expected = "1.2.3"; } ]; }' probes "expected"
bad '{ probes = [ { command = "example-app"; kind = "version"; extract = "last-line"; } ]; }' probes "extract"
bad '{ pins.rules = [ { kind = "guess"; } ]; }' pins.rules "kind"
bad '{ pins.latest = [ { id = "x"; adapter = "scrape"; } ]; }' pins.latest "adapter"
bad '{ checks.e2e = [ { name = "x"; script = ./x.sh; phase = "never"; } ]; }' checks.e2e "phase"
bad '{ checks.floors = [ { command = "x"; argv = [ ]; minimum = "1"; compare = "lexical"; } ]; }' checks.floors "compare"
bad '{ reloadHooks.r = { command = [ "x" ]; timeout = 1; onFailure = "explode"; }; }' reloadHooks.r.onFailure \
  "dotsteward.components.example-app.reloadHooks.r.onFailure"
bad '{ bootstrap.backupPaths = [ "relative/path" ]; }' bootstrap.backupPaths "dotsteward.components.example-app.bootstrap.backupPaths"
bad '{ agentRulesTargets = [ { path = "~/.example-app/AGENTS.md"; } ]; }' agentRulesTargets "path"

# Several modules contribute to the same component (lists concatenate; the
# order of definitions is the module system's, so it is not asserted).
assert_nix_eq '["~/a","~/b"]' \
  'lib.sort lib.lessThan ((evalComponents [ { dotsteward.components.example-app = { method = "nix"; bootstrap.backupPaths = [ "~/a" ]; }; } { dotsteward.components.example-app.bootstrap.backupPaths = [ "~/b" ]; } ]).example-app.bootstrap.backupPaths)'
