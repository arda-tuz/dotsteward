# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* and agents_* variables come from the harness and the helpers
# dotsteward.files (SPEC 3.3; R7): the verifier (core:files) and the
# installer agree for a user that is not the instance's check identity. The
# installer is the dotstewardFiles activation entry, which runs
# `install -D -m MODE SOURCE TARGET` with the target expanded against the
# runtime home directory; it is replayed here for a non-owner username.
# policy "always": a regular non-symlink file with the source bytes and the
# declared mode; policy "if-missing": a regular non-symlink file (the
# application owns its content after the first install).
# shellcheck source=tests/cli/e2e/helpers.sh
source "$DS_REPO_ROOT/tests/cli/e2e/helpers.sh"

# The check identity is someone else; the runtime user is dotsteward-test
# with this HOME.
sed -i 's/^username = .*/username = "example-owner"/' "$agents_inst/workstation.toml"
mkdir -p "$agents_inst/files"
printf 'theme = "dark"\n' >"$agents_inst/files/app.conf"
printf 'first = true\n' >"$agents_inst/files/seed.conf"
manifest_edit '.files = {
  "app-conf": {source: "<instance>/files/app.conf", target: "~/.config/example/app.conf", mode: "0640", policy: "always"},
  "seed-conf": {source: "<instance>/files/seed.conf", target: "~/.config/example/seed.conf", mode: "0600", policy: "if-missing"}}'
publish_instance

install_files() {
  local source target mode policy
  while IFS=$'\t' read -r _ source target mode policy; do
    source=$agents_inst/${source#<instance>/}
    target=$HOME/${target#\~/}
    if [[ $policy == if-missing && -e $target ]]; then
      continue
    fi
    install -D -m "$mode" "$source" "$target"
  done < <(jq -r '.files | to_entries[] | [.key, .value.source, .value.target, .value.mode, .value.policy] | @tsv' \
    "$agents_manifest")
}

# Before activation the files are missing.
assert_exit 1 run_e2e --json --keep-going
assert_eq "$(jq -cn --arg home "$HOME" '[
  ["core:files", "file-missing", ($home + "/.config/example/app.conf")],
  ["core:files", "file-missing", ($home + "/.config/example/seed.conf")]]')" "$(findings)"
assert_contains "$DS_STDOUT" "file app-conf missing: $HOME/.config/example/app.conf"

install_files
assert_exit 0 run_e2e
assert_eq "-rw-r----- -rw-------" "$(stat -c %A "$HOME/.config/example/app.conf" "$HOME/.config/example/seed.conf" | tr '\n' ' ' | sed 's/ $//')"

# The application changes the if-missing file: still verified.
printf 'first = false\n' >"$HOME/.config/example/seed.conf"
assert_exit 0 run_e2e

# Other bytes, another mode, a symlink.
printf 'theme = "light"\n' >"$HOME/.config/example/app.conf"
assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg home "$HOME" '[["core:files", "file-content-mismatch", ($home + "/.config/example/app.conf")]]')" \
  "$(findings)"
assert_contains "$DS_STDOUT" "file app-conf differs from $agents_inst/files/app.conf: $HOME/.config/example/app.conf"
install_files
chmod 0644 "$HOME/.config/example/app.conf"
assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg home "$HOME" '[["core:files", "file-mode-mismatch", ($home + "/.config/example/app.conf")]]')" \
  "$(findings)"
assert_contains "$DS_STDOUT" "file app-conf has mode 0644, expected 0640: $HOME/.config/example/app.conf"
rm "$HOME/.config/example/seed.conf"
ln -s "$agents_inst/files/seed.conf" "$HOME/.config/example/seed.conf"
install_files
assert_exit 1 run_e2e --json
assert_eq "$(jq -cn --arg home "$HOME" '[["core:files", "file-not-regular", ($home + "/.config/example/seed.conf")]]')" \
  "$(findings)"
assert_contains "$DS_STDOUT" "file seed-conf is not a regular file: $HOME/.config/example/seed.conf"
rm "$HOME/.config/example/seed.conf"
install_files
assert_exit 0 run_e2e

# A substituted source is a store file: the mirror cannot carry it, a
# generation can.
manifest_edit '.files["app-conf"].source = "<store>/dotsteward-file-app-conf"'
publish_instance
assert_exit 1 run_e2e --json
assert_eq '[["core:files","source-unresolvable","<store>/dotsteward-file-app-conf"]]' "$(findings)"
make_generation
store=$DS_TEST_ROOT/store-files
mkdir -p "$store"
cp "$agents_inst/files/app.conf" "$store/dotsteward-file-app-conf"
jq --arg source "$store/dotsteward-file-app-conf" '.files["app-conf"].source = $source' "$agents_manifest" \
  >"$agents_gen/home-path/share/dotsteward/manifest.json"
assert_exit 0 run_e2e --generation "$agents_gen"
assert_eq "" "$(temp_dirs)"
