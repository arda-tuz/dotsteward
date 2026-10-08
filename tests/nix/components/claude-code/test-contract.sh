# shellcheck shell=bash
# shellcheck disable=SC2016 # Nix expressions in single quotes
# The claude-code catalog component with its default method:
# official-binary on both platforms, the per-platform release pin, the
# settings targets, backup paths, managed link, skill link root and agent
# rules target, as an instance that enables it sees them in the manifest
# and in the Home Manager configuration.
# shellcheck source=tests/nix/components/claude-code/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/claude-code/helpers.sh"

assert_cc_eq 'true' 'dsLib.catalog ? claude-code' "claude-code is a catalog component"

# official_binary RELEASE_PLATFORM: the expected install block.
official_binary() {
  jq -n --arg release "$1" '{
    pin: ("agent_tools.claude-code." + $release),
    asset: { linux: "linux-x64/claude", darwin: "darwin-arm64/claude" },
    member: "claude",
    dest: "~/.local/bin/claude",
    versionArgv: ["--version"],
    versionRegex: "^([0-9]+[.][0-9]+[.][0-9]+) [(]Claude Code[)]",
    policy: "at-least",
    verify: "sha256"
  }'
}

# The manifest entry on each system: the default method, the methods per
# platform, the modes of both profiles and the release pin of the system.
for pair in x86_64-linux:linux-x64 aarch64-darwin:darwin-arm64; do
  system=${pair%%:*}
  release=${pair#*:}
  expected=$(jq -n --argjson install "$(official_binary "$release")" '{
    name: "claude-code",
    source: "catalog",
    method: "official-binary",
    profiles: null,
    platforms: ["linux", "darwin"],
    options: {},
    modes: { workstation: "fresh", baseline: "adopt" },
    supported_methods: {
      linux: ["official-binary", "deb", "external"],
      darwin: ["official-binary", "external"]
    },
    install: $install
  }')
  assert_cc_eq "$expected" "ccEntry (cc { }) \"$system\"" "manifest entry on $system"
done

# The version regex matches what the native build prints.
regex=$(cc_json '(ccEntry (cc { }) "x86_64-linux").install.versionRegex' | jq -r .)
line='2.1.285 (Claude Code)'
[[ $line =~ $regex ]] || ds_fail "the version regex does not match: $line"
assert_eq "2.1.285" "${BASH_REMATCH[1]}" "version extracted by the regex"
[[ ! 'claude 2.1.285' =~ $regex ]] || ds_fail "the version regex matches another program's output"

# Settings targets: settings.json is created, ~/.claude.json is only
# edited and never backed up (it holds the application's own state).
for system in x86_64-linux aarch64-darwin; do
  assert_cc_eq '{
    "claude-settings": {
      "component": "claude-code", "path": "~/.claude/settings.json", "format": "json",
      "create_if_missing": true, "create_mode": "0644", "backup": true, "reload": null
    },
    "claude-global": {
      "component": "claude-code", "path": "~/.claude.json", "format": "json",
      "create_if_missing": false, "create_mode": "0644", "backup": false, "reload": null
    }
  }' "lib.filterAttrs (_: t: t.component == \"claude-code\") (ccManifest (cc { }) \"$system\").settings_targets" \
    "settings targets on $system"
done
assert_cc_eq '{}' 'lib.filterAttrs (_: h: h.component == "claude-code") (ccManifest (cc { }) "x86_64-linux").reload_hooks' \
  "no reload hooks"

# Bootstrap backups, the managed link checked and removed by rollback, the
# skill link root and the agent rules target.
assert_cc_eq '{
  "backup": [true, true, true],
  "links": ["~/.claude/CLAUDE.md"],
  "linkRoot": { "component": "claude-code", "target_prefix": "../../.agents/skills/" },
  "rules": [{ "component": "claude-code", "path": ".claude/CLAUDE.md", "force": false }],
  "legacy": [],
  "excluded": []
}' 'let
  m = ccManifest (cc { }) "x86_64-linux";
  c = ccComponent (cc { }) "x86_64-linux";
in {
  backup = map (p: builtins.elem p m.backup_paths) [ "~/.claude/CLAUDE.md" "~/.claude/settings.json" "~/.claude/skills" ];
  links = lib.filter (lib.hasPrefix "~/.claude") m.managed_links;
  linkRoot = m.skill_layout.link_roots."~/.claude/skills";
  rules = lib.filter (t: t.component == "claude-code") m.agent_rules.targets;
  legacy = c.skillLayout.legacyRoots;
  excluded = c.skillLayout.excludedSubtrees;
}' "backups, managed link, skill layout and agent rules"
assert_cc_eq '["~/.claude/CLAUDE.md","~/.claude/settings.json","~/.claude/skills"]' \
  '(ccComponent (cc { }) "x86_64-linux").bootstrap.backupPaths' "backup paths of the component"

# The agent rules file is linked to ~/.claude/CLAUDE.md on both platforms
# and in every profile; no package joins home.packages (the methods install
# the command outside Home Manager).
for system in x86_64-linux aarch64-darwin; do
  assert_cc_eq '{"force":false,"rules":true,"packages":false}' "let h = ccHome (cc { }) \"$system\"; in {
    force = h.home.file.\".claude/CLAUDE.md\".force;
    rules = h.dotsteward.agentRules.storePath != null
      && toString h.home.file.\".claude/CLAUDE.md\".source == h.dotsteward.agentRules.storePath;
    packages = builtins.any (p: lib.hasInfix \"claude\" (lib.getName p)) h.home.packages;
  }" "agent rules link on $system"
done
assert_cc_eq 'true' 'let h = homeOf (cc { }) "x86_64-linux" "baseline"; in h.home.file ? ".claude/CLAUDE.md"' \
  "agent rules link in the adopt-mode profile"

# Nothing the spec does not list: no probes, E2E commands, floors, hooks,
# snapshots, prerequisites, adopt paths, detectors, flake inputs or
# resolved versions (an instance's adopt-mode profile checks no Claude Code).
assert_cc_eq '{
  "probes": [], "commands": [], "e2e": [], "agents": [], "floors": [],
  "hooks": [], "snapshots": [], "apt": [], "adopt": [], "restore": [],
  "detectors": {}, "flakeInputs": [], "resolved": {}, "updatePaths": [], "options": {}
}' 'let c = ccComponent (cc { }) "x86_64-linux"; in {
  inherit (c) probes options;
  inherit (c.checks) commands e2e agents floors;
  hooks = lib.concatLists (lib.attrValues c.hooks);
  inherit (c.bootstrap) snapshots;
  inherit (c.bootstrap.prerequisites) apt;
  adopt = c.rebuild.adoptPaths;
  restore = c.rollback.forceLinkedRestore;
  inherit (c.preflight) detectors;
  inherit (c.pins) flakeInputs;
  resolved = c.pins.resolvedVersions;
  inherit (c.gate) updatePaths;
}' "no undeclared contributions"

# The user documentation is the component README.
assert_cc_eq 'true' 'let c = ccComponent (cc { }) "x86_64-linux"; in c.docs != null && baseNameOf (toString c.docs) == "README.md"' \
  "docs"
[[ -f $cc_component_dir/README.md && -f $cc_component_dir/maintenance.md ]] ||
  ds_fail "README.md and maintenance.md are required in modules/components/claude-code"

# The manifest does not depend on the profile.
assert_cc_eq 'true' 'let i = cc { }; in
  (homeOf i "x86_64-linux" "workstation").dotsteward.manifest == (homeOf i "x86_64-linux" "baseline").dotsteward.manifest' \
  "profile-independent manifest"
