# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Helpers for the pins latest tests (tests/engines/pins/latest). Not a test
# file.
#
# latest_world builds an offline world for `dotsteward pins latest`:
#   - the synthetic instance fixtures/instance at $inst, whose manifest
#     mirror declares every latest adapter; "@HTTPFIX@" in its files becomes
#     the loopback server URL and "@REV:OWNER/REPO:REF@" the commit REF
#     names in the fake GitHub remote OWNER/REPO;
#   - a loopback HTTP server (tests/lib/httpfix.py) over a copy of
#     fixtures/www at $www ("@HTTPFIX@" replaced there too) plus the shared
#     APT index under apt/dists/stable/main/binary-amd64/Packages;
#   - bare git repositories under $github, reached through
#     `url.<path>.insteadOf https://github.com/` in the test's global git
#     configuration, so `git ls-remote https://github.com/OWNER/REPO` never
#     leaves the machine;
#   - the gh stub with canned REST answers (releases/latest of example-term,
#     example-cli, example-tool and the framework, the three compares), and
#     the apt-cache stub with example-app 1.2.3 available.
#
#   latest ARG...           `dotsteward --instance $inst pins latest ARG...`
#   dotsteward ARG...       the framework CLI under test
#   rev OWNER/REPO REF      the commit REF names in the fake remote
#   remote_repo OWNER/REPO  a work repository at $sources/OWNER/REPO (one
#                           commit on main)
#   publish OWNER/REPO      (re)creates the bare remote of a work repository
#   json_edit FILE PYTHON   runs PYTHON with `data` bound to FILE's JSON, then
#                           writes it back with the lock serializer
#   declare_latest JSON...  replaces the manifest's latest declarations with
#                           the given objects (each one JSON text)
#   clear_latest            removes every latest declaration of the manifest
#   row ID [JQ]             the report row with ID (or JQ applied to it) from
#                           $report, compact JSON
#   statuses                "status id" lines of $report, in report order
#   latest_gh_routes        adds the canned gh answers of the world; gh tries
#                           routes in order, so a test that needs another
#                           answer clears the routes, adds its own first and
#                           then calls this

latest_fixtures=$DS_REPO_ROOT/tests/engines/pins/latest/fixtures
inst=$DS_TEST_ROOT/inst
www=$DS_TEST_ROOT/www
github=$DS_TEST_ROOT/github
sources=$DS_TEST_ROOT/sources
# shellcheck disable=SC2034 # read by the test files
versions=$inst/versions.lock.json
# shellcheck disable=SC2034 # read by the test files
skills=$inst/agent/skills.lock.json
manifest=$inst/.dotsteward/manifest.x86_64-linux.json
report=$DS_TEST_ROOT/report.json

# shellcheck source=tests/lib/bare-remote.sh
source "$DS_REPO_ROOT/tests/lib/bare-remote.sh"

dotsteward() {
  "$DS_REPO_ROOT/cli/dotsteward" "$@"
}

latest() {
  "$DS_REPO_ROOT/cli/dotsteward" --instance "$inst" pins latest "$@"
}

remote_repo() {
  local dir=$sources/$1
  mkdir -p "$(dirname "$dir")"
  ds_git_repo "$dir"
  printf '%s\n' "$dir"
}

publish() {
  local bare=$github/$1
  rm -rf -- "$bare"
  mkdir -p "$(dirname "$bare")"
  ds_bare_remote "$bare" "$sources/$1"
}

rev() {
  git -C "$github/$1" rev-parse --verify --quiet "$2^{commit}"
}

json_edit() {
  local file=$1 code=$2
  python3 - "$file" "$code" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
exec(sys.argv[2], {"data": data})
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

declare_latest() {
  python3 - "$manifest" "$@" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["pins"]["latest"] = [json.loads(text) for text in sys.argv[2:]]
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

clear_latest() {
  json_edit "$manifest" 'data["pins"]["latest"] = []'
}

row() {
  jq -c --arg id "$1" ".items[] | select(.id == \$id) | ${2:-.}" "$report"
}

statuses() {
  jq -r '.items[] | "\(.status) \(.id)"' "$report"
}

# Replaces @HTTPFIX@ and @REV:OWNER/REPO:REF@ in every regular file under
# DIR.
_latest_substitute() {
  python3 - "$1" "$DS_HTTPFIX_URL" "$github" <<'PY'
import pathlib
import re
import subprocess
import sys

root, url, github = sys.argv[1:]


def commit(match):
    repo, ref = match.group(1), match.group(2)
    result = subprocess.run(
        ["git", "-C", f"{github}/{repo}", "rev-parse", "--verify", "--quiet", ref + "^{commit}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.exit(f"no commit {ref} in the fake remote {repo}")
    return result.stdout.strip()


for path in sorted(pathlib.Path(root).rglob("*")):
    if path.is_file() and not path.is_symlink():
        text = path.read_text(encoding="utf-8")
        new = re.sub(r"@REV:([^:@]+):([^@]+)@", commit, text.replace("@HTTPFIX@", url))
        if new != text:
            path.write_text(new, encoding="utf-8")
PY
}

_latest_remotes() {
  local dir
  git config --global url."$github/".insteadOf https://github.com/

  dir=$(remote_repo example-org/nixpkgs)
  git -C "$dir" branch nixos-25.05
  git -C "$dir" checkout -q -b nixos-25.11
  ds_git_commit "$dir" channel.txt 25.11-a "chore: channel 25.11 a"
  ds_git_commit "$dir" channel.txt 25.11-b "chore: channel 25.11 b"
  git -C "$dir" checkout -q -b nixos-26.05
  ds_git_commit "$dir" channel.txt 26.05 "chore: channel 26.05"
  git -C "$dir" branch nixos-unstable
  git -C "$dir" checkout -q main
  publish example-org/nixpkgs

  dir=$(remote_repo example-org/home-manager)
  git -C "$dir" branch release-25.11
  git -C "$dir" branch master
  publish example-org/home-manager

  dir=$(remote_repo example-org/example-term)
  git -C "$dir" tag v0.8.0
  ds_git_commit "$dir" VERSION 0.9.0 "chore: release 0.9.0"
  git -C "$dir" tag v0.9.0
  publish example-org/example-term

  dir=$(remote_repo example-org/example-lib)
  git -C "$dir" tag v2.0.0
  ds_git_commit "$dir" VERSION 2.1.0 "chore: release 2.1.0"
  git -C "$dir" tag v2.1.0
  ds_git_commit "$dir" VERSION 3.0.0-beta.1 "chore: beta"
  git -C "$dir" tag v3.0.0-beta.1
  git -C "$dir" tag nightly
  publish example-org/example-lib

  local repo
  for repo in example-plugins example-watch example-skills; do
    dir=$(remote_repo "example-org/$repo")
    ds_git_commit "$dir" CHANGES.txt "second" "chore: second commit"
    publish "example-org/$repo"
  done

  dir=$(remote_repo example-org/example-tool)
  git -C "$dir" tag -a v1.0.0 -m "release 1.0.0"
  ds_git_commit "$dir" CHANGES.txt "unreleased" "chore: unreleased work"
  publish example-org/example-tool

  dir=$(remote_repo NixOS/nix)
  git -C "$dir" tag 2.30.0
  ds_git_commit "$dir" VERSION 2.31.1 "chore: release 2.31.1"
  git -C "$dir" tag 2.31.1
  ds_git_commit "$dir" VERSION 2.32.0pre "chore: prerelease"
  git -C "$dir" tag 2.32.0pre20260901
  publish NixOS/nix

  dir=$(remote_repo example/dotsteward)
  git -C "$dir" tag v0.1.0
  ds_git_commit "$dir" VERSION 0.2.0 "chore: release 0.2.0"
  git -C "$dir" tag v0.2.0
  publish example/dotsteward
}

latest_gh_routes() {
  local gh=$latest_fixtures/gh
  ds_stub_route gh "api repos/example-org/example-term/releases/latest" \
    --stdout-file "$(ds_fixture common/github/release-latest.json)"
  ds_stub_route gh "api repos/example-org/example-cli/releases/latest" --stdout-file "$gh/example-cli-release.json"
  ds_stub_route gh "api repos/example-org/example-tool/releases/latest" --stdout-file "$gh/example-tool-release.json"
  ds_stub_route gh "api repos/example/dotsteward/releases/latest" --stdout-file "$gh/framework-release.json"
  ds_stub_route gh "api repos/example-org/example-plugins/compare/*" --stdout-file "$gh/compare-plugins.json"
  ds_stub_route gh "api repos/example-org/example-watch/compare/*" --stdout-file "$gh/compare-watch.json"
  ds_stub_route gh "api repos/example-org/example-skills/compare/*" --stdout-file "$gh/compare-skills.json"
}

latest_world() {
  rm -rf -- "$www" "$inst" "$github" "$sources"
  cp -R -- "$latest_fixtures/www" "$www"
  mkdir -p "$www/apt/dists/stable/main/binary-amd64"
  cp -- "$(ds_fixture common/apt/Packages)" "$www/apt/dists/stable/main/binary-amd64/Packages"
  ds_httpfix_start "$www"
  _latest_substitute "$www"

  _latest_remotes

  cp -R -- "$latest_fixtures/instance" "$inst"
  _latest_substitute "$inst"

  ds_use_stubs gh apt-cache
  latest_gh_routes
  ds_apt_available example-app 1.2.3
}
