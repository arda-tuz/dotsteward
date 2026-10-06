# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# shellcheck disable=SC2016 # Nix expressions and expected shell text in single quotes
# modules/core files: dotsteward.files.<id> installed by one activation
# entry after writeBoundary, with build-time substitutions.
# shellcheck source=tests/nix/core/helpers.sh
source "$DS_REPO_ROOT/tests/nix/core/helpers.sh"

# No files: no activation entry.
assert_core_eq 'false' '(homeOf { }).home.activation ? dotstewardFiles'

files='{
  dotsteward.files = {
    example-term-config = {
      source = fixtures + "/instance/files/example-term.conf";
      target = "~/.config/example-term/config.conf";
      policy = "if-missing";
      substitute = { "@HOME@" = "/home/alice"; "@NAME@" = "example"; };
    };
    example-term-verbatim = {
      source = fixtures + "/instance/files/example-term.conf";
      target = "~/.local/share/example term/verbatim.conf";
      mode = "0600";
    };
  };
}'
config="{ modules = [ $files ]; }"

# Substitutions are applied at build time; without substitutions the source
# itself is installed.
assert_core_eq '"home = /home/alice\nname = example\nmode = verbatim\n"' \
  "(homeOf $config).dotsteward.files.example-term-config.finalSource.text"
assert_core_eq 'true' \
  "(homeOf $config).dotsteward.files.example-term-verbatim.finalSource == fixtures + \"/instance/files/example-term.conf\""

# One activation entry after writeBoundary, files in id order, if-missing
# guarded by an existence test, targets expanded with the home directory.
actual=$(core_json "let
  c = homeOf $config;
  install = \"\${(pkgsFor \"x86_64-linux\").coreutils}/bin/install\";
  config = \"\${c.dotsteward.files.example-term-config.finalSource}\";
  verbatim = \"\${c.dotsteward.files.example-term-verbatim.finalSource}\";
in {
  inherit (c.home.activation.dotstewardFiles) after before;
  inherit config verbatim;
  configText = c.dotsteward.files.example-term-config.finalSource.text;
  data = c.home.activation.dotstewardFiles.data;
  expected = ''
    if [[ ! -e /home/alice/.config/example-term/config.conf ]]; then
      \$DRY_RUN_CMD \${install} -D -m 0644 \${config} /home/alice/.config/example-term/config.conf
    fi
    \$DRY_RUN_CMD \${install} -D -m 0600 \${verbatim} '/home/alice/.local/share/example term/verbatim.conf'
  '';
}")
json_check "$actual" '[.after, .before]' '[["writeBoundary"],[]]'
assert_eq "$(jq -r .expected <<<"$actual")" "$(jq -r .data <<<"$actual")" "activation script"

# The entry runs in a temporary home. An evaluation creates no store files,
# so the test puts the substituted text and the fixture in place of the two
# store paths. A run installs the files; if-missing keeps a changed file,
# always restores it.
script=$DS_TEST_ROOT/files.sh
substituted=$DS_TEST_ROOT/substituted.conf
jq -j .configText <<<"$actual" >"$substituted"
jq -r .data <<<"$actual" |
  sed "s|/home/alice|$HOME|g; s|[^ ]*/bin/install|install|;
    s|$(jq -r .config <<<"$actual")|$substituted|; s|$(jq -r .verbatim <<<"$actual")|$nix_core_fixtures/instance/files/example-term.conf|" >"$script"
DRY_RUN_CMD='' bash "$script"
assert_eq $'home = /home/alice\nname = example\nmode = verbatim' "$(<"$HOME/.config/example-term/config.conf")" "substituted file"
assert_eq "$(<"$nix_core_fixtures/instance/files/example-term.conf")" "$(<"$HOME/.local/share/example term/verbatim.conf")" "verbatim file"
assert_file_mode "$HOME/.config/example-term/config.conf" 644
assert_file_mode "$HOME/.local/share/example term/verbatim.conf" 600
printf 'changed\n' >"$HOME/.config/example-term/config.conf"
printf 'changed\n' >"$HOME/.local/share/example term/verbatim.conf"
DRY_RUN_CMD='' bash "$script"
assert_eq changed "$(<"$HOME/.config/example-term/config.conf")" "if-missing keeps the file"
assert_eq "$(<"$nix_core_fixtures/instance/files/example-term.conf")" "$(<"$HOME/.local/share/example term/verbatim.conf")" "always restores"

# Targets are home paths; modes are octal; policies are known.
assert_core_fails '(homeOf { modules = [ { dotsteward.files.x = { source = fixtures + "/instance/files/example-term.conf"; target = "/etc/x"; }; } ]; }).home.activation.dotstewardFiles.data' \
  "dotsteward.files.x.target"
assert_core_fails '(homeOf { modules = [ { dotsteward.files.x = { source = fixtures + "/instance/files/example-term.conf"; target = "~/x"; mode = "644"; }; } ]; }).home.activation.dotstewardFiles.data' \
  "dotsteward.files.x.mode"
assert_core_fails '(homeOf { modules = [ { dotsteward.files.x = { source = fixtures + "/instance/files/example-term.conf"; target = "~/x"; policy = "never"; }; } ]; }).home.activation.dotstewardFiles.data' \
  "dotsteward.files.x.policy"

# The manifest exports the installed bytes' store path, target, mode and
# policy, so E2E verifies the same file.
actual=$(core_json "let c = homeOf $config; in { manifest = c.dotsteward.manifest.files; source = \"\${c.dotsteward.files.example-term-config.finalSource}\"; }")
json_check "$actual" '.manifest["example-term-config"] | del(.source)' '{"mode":"0644","policy":"if-missing","target":"~/.config/example-term/config.conf"}'
json_check "$actual" '.manifest["example-term-config"].source == .source' 'true'
json_check "$actual" '.manifest["example-term-verbatim"] | del(.source)' '{"mode":"0600","policy":"always","target":"~/.local/share/example term/verbatim.conf"}'
