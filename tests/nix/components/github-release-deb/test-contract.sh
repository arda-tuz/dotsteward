# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and craft_* variables come from the harness and helpers.sh
# shellcheck disable=SC2016 # Nix and jq programs in single quotes
# The contract values of the catalog components built by
# modules/core/github-release-deb.nix (pdfcraft, gridcraft, wordcraft,
# deckcraft, craft-anything), as lib.mkInstance evaluates them on Linux:
# Linux only, the deb method only, the package of the component's own name
# from the asset <name>-{version}-linux-x86_64.deb of the GitHub releases of
# storytold/<name> (verified against SHA256SUMS.txt, served by the local
# APT bridge), the pin desktop_packages.<name>, the commands <name> and
# <name>-cli, the shared E2E hook on every profile, one download-pin rule
# and one github-release latest row, the component README as its docs, and
# no probe, hook, backup path or managed link.
# shellcheck source=tests/nix/components/github-release-deb/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/github-release-deb/helpers.sh"

names=(pdfcraft gridcraft wordcraft deckcraft craft-anything)

# expect FACTS LABEL JQ_PROGRAM: the program, run over FACTS with $n (the
# component), $r (its repository) and $a (its asset template), is true.
expect() {
  jq -e --arg n "$name" --arg r "$repo" --arg a "$asset" "$3" >/dev/null <<<"$1" ||
    ds_fail "$name: $2: $(jq -c . <<<"$1")"
}

all=$(craft_json 'let
  inst = craft { };
  m = manifestOf inst "x86_64-linux";
  of = name: lib.filter (e: (e.component or null) == name);
in lib.genAttrs names (name: let c = componentOf inst "x86_64-linux" name; in {
  entry = entryOf inst "x86_64-linux" name;
  commands = map (e: e.command) (of name m.checks.commands);
  e2e = map (e: { inherit (e) name phase profiles; script = baseNameOf e.script; }) (of name m.checks.e2e);
  rules = of name m.pins.rules;
  latest = of name m.pins.latest;
  probes = of name m.probes;
  hooks = lib.filterAttrs (_: list: list != [ ]) c.hooks;
  backups = c.bootstrap.backupPaths;
  links = c.rollback.managedLinks;
  docs = toString c.docs == toString (repoRoot + "/modules/components/${name}/README.md");
})')

for name in "${names[@]}"; do
  facts=$(jq -c --arg n "$name" '.[$n]' <<<"$all")
  [[ $facts != null ]] || ds_fail "$name is not evaluated"
  repo=storytold/$name
  asset="$name-{version}-linux-x86_64.deb"

  expect "$facts" "entry" '.entry | .name == $n and .source == "catalog" and .method == "deb"
    and .platforms == ["linux"] and .supported_methods == {linux: ["deb"], darwin: []}'
  expect "$facts" "install block" '.entry.install == {
    pin: ("desktop_packages." + $n), packageNames: [$n], architecture: "amd64", verifyAfterInstall: true,
    apt: [], aptSources: [], githubRelease: {repository: $r, assets: {amd64: $a}, checksums: "SHA256SUMS.txt"}}'
  expect "$facts" "commands" '.commands == [$n, ($n + "-cli")]'
  expect "$facts" "e2e hook" '(.e2e | length) == 1 and (.e2e[0] | .name == "package" and .phase == "main"
    and .profiles == null and (.script | endswith("-github-release-deb-e2e.sh")))'
  expect "$facts" "pins rules" '.rules == [{component: $n, kind: "download-pin",
    at: ("desktop_packages." + $n), version_field: "minimum_version",
    url_contains: ("https://github.com/" + $r + "/releases/download/v{.minimum_version}/" + $n + "-{.minimum_version}-linux-x86_64.deb")}]'
  expect "$facts" "latest row" '.latest == [{component: $n,
    id: ("desktop_packages." + $n), adapter: "github-release", repo: $r, tag_prefix: "v",
    at: ("desktop_packages." + $n), asset: $a}]'
  expect "$facts" "nothing else" '.probes == [] and .hooks == {} and .backups == [] and .links == [] and .docs == true'
done

# The shared E2E hook is an executable file next to the helper.
[[ -x $craft_core/github-release-deb-e2e.sh ]] || ds_fail "modules/core/github-release-deb-e2e.sh is not executable"
