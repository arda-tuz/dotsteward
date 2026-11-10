# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The install step of the Pi package follows the workspaces of the release it builds: each package
# below packages/ that is published (not "private", such as the evals of the release) becomes a
# copy of itself in node_modules in place of its link (the coding-agent workspace itself is the
# package), then the links that would dangle go. A release that drops or adds a workspace builds
# without an edit of the derivation; a workspace without a name, or one npm did not link, stops the
# build and says so. The step runs here as the builder runs it, against a synthetic tree.
# shellcheck source=tests/nix/components/opencode-pi/helpers.sh
source "$DS_REPO_ROOT/tests/nix/components/opencode-pi/helpers.sh"

install=$(op_json 'let p = piFor "x86_64-linux"; in { inherit (p) postInstall npmWorkspace; }')
workspace=$(jq -r .npmWorkspace <<<"$install")
script=$(jq -r .postInstall <<<"$install")

# synthetic_tree DIR NAME:DIRECTORY...: a build tree with those workspaces, each linked into the
# node_modules of the output as npm leaves it, and a command link into the coding agent.
synthetic_tree() {
  local tree=$1 entry name directory
  shift
  mkdir -p "$tree/build/$workspace" "$tree/out/lib/node_modules/pi-monorepo/node_modules/.bin"
  printf '{"name": "@earendil-works/pi-coding-agent"}\n' >"$tree/build/$workspace/package.json"
  for entry in "$@" "@earendil-works/pi-coding-agent:${workspace#packages/}"; do
    name=${entry%%:*}
    directory=${entry#*:}
    mkdir -p "$tree/build/packages/$directory/dist"
    [[ -e $tree/build/packages/$directory/package.json ]] ||
      printf '{"name": "%s"}\n' "$name" >"$tree/build/packages/$directory/package.json"
    printf 'code of %s\n' "$name" >"$tree/build/packages/$directory/dist/index.js"
    mkdir -p "$(dirname "$tree/out/lib/node_modules/pi-monorepo/node_modules/$name")"
    ln -s "$tree/build/packages/$directory" "$tree/out/lib/node_modules/pi-monorepo/node_modules/$name"
  done
  ln -s ../@earendil-works/pi-coding-agent/dist/cli.js "$tree/out/lib/node_modules/pi-monorepo/node_modules/.bin/pi"
}

# run_install DIR: the install step in the build tree, with the variables of the builder.
run_install() {
  (cd "$1/build" && out=$1/out npmWorkspace=$workspace bash -euo pipefail -c "postInstall() {
$script
}
postInstall")
}

# A release whose workspaces are not those of an older one: client, protocol and server are
# gone, env and schema are new, and one has no scope.
tree=$DS_TEST_ROOT/release
mkdir -p "$tree/build/packages/evals"
printf '{"name": "@earendil-works/pi-evals", "private": true}\n' >"$tree/build/packages/evals/package.json"
synthetic_tree "$tree" @earendil-works/pi-ai:ai @earendil-works/pi-agent-core:agent @earendil-works/pi-tui:tui \
  @earendil-works/pi-env:env @earendil-works/pi-schema:schema example-plain:plain @earendil-works/pi-evals:evals
assert_exit 0 run_install "$tree"
nm=$tree/out/lib/node_modules/pi-monorepo/node_modules
for name in @earendil-works/pi-ai @earendil-works/pi-agent-core @earendil-works/pi-tui @earendil-works/pi-env \
  @earendil-works/pi-schema example-plain; do
  [[ -d $nm/$name && ! -L $nm/$name ]] || ds_fail "$name is not a copy in node_modules"
  assert_eq "code of $name" "$(<"$nm/$name/dist/index.js")" "the copy of $name"
done
for name in @earendil-works/pi-coding-agent @earendil-works/pi-evals; do
  [[ ! -e $nm/$name && ! -L $nm/$name ]] || ds_fail "$name is no copy in node_modules"
done
assert_eq "" "$(find "$nm" -type l -lname '*/packages/*' -print)" "no link into the build tree is left"
assert_eq "" "$(find "$nm/.bin" -xtype l -print)" "no command link dangles"

# A workspace without a name stops the build and names the file to look at.
tree=$DS_TEST_ROOT/unnamed
mkdir -p "$tree/build/packages/broken"
printf '{"version": "1.0.0"}\n' >"$tree/build/packages/broken/package.json"
synthetic_tree "$tree" @earendil-works/pi-ai:ai
assert_exit 1 run_install "$tree"
assert_contains "$DS_STDERR" "packages/broken/package.json has no name"

# A published workspace that npm did not link: the layout is not what the package expects.
tree=$DS_TEST_ROOT/unlinked
mkdir -p "$tree/build/packages/loose"
printf '{"name": "@earendil-works/pi-loose"}\n' >"$tree/build/packages/loose/package.json"
synthetic_tree "$tree" @earendil-works/pi-ai:ai
assert_exit 1 run_install "$tree"
assert_contains "$DS_STDERR" "@earendil-works/pi-loose (packages/loose) is not linked in node_modules"
