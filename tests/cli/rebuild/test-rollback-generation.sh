# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# rollback --latest, generation branch: with a recorded
# previous Home Manager generation, rollback activates it instead of
# removing links. The manifest is the current generation's (the active Home
# Manager profile), else the instance's mirror. Without a record, or with a
# record that is not a generation, --apply refuses before any change. The
# default login shell follows the platform (Linux /bin/bash, macOS
# /bin/zsh).
# shellcheck source=tests/cli/rebuild/helpers.sh
source "$DS_REPO_ROOT/tests/cli/rebuild/helpers.sh"

record=$rb_current/previous-generation
ds_passwd_set "$USER" "$rb_zsh"

# No record yet: the plan says so and --apply refuses.
assert_exit 0 run_rollback --latest --dry-run
assert_contains "$DS_STDOUT" "3. No previous Home Manager state is recorded; --apply refuses until rebuild --switch has run"
assert_exit 0 run_rollback --latest --dry-run --json
printf '%s\n' "$DS_STDOUT" >"$DS_TEST_ROOT/plan.json"
assert_json "$DS_TEST_ROOT/plan.json" '.previous_generation == null
  and .steps[2] == { id: "home-manager", action: "none", generation: null, links: [] }'
assert_exit 1 run_rollback --latest --apply
assert_contains "$DS_STDERR" "[dotsteward] ERROR: no previous Home Manager state is recorded: $record (run rebuild --switch first)"
assert_calls
assert_eq "$rb_zsh" "$(ds_passwd_field "$USER" 7)"

# The current generation's manifest wins over the mirror.
manifest_edit '.managed_links = ["~/.zshrc"]'
previous=$(make_generation home-manager-previous)
current=$(make_generation home-manager-current)
use_generation "$current"
manifest_edit '.managed_links = ["~/.mirror-only"]'
store_link "$HOME/.zshrc"
cat >"$previous/activate" <<EOF
#!$BASH
source $(printf %q "$DS_REPO_ROOT/tests/lib/harness.sh")
ds_record_call activate-previous "\$@"
if [[ -f $(printf %q "$DS_TEST_ROOT/previous-exit") ]]; then
  exit "\$(<$(printf %q "$DS_TEST_ROOT/previous-exit"))"
fi
EOF

# A record that is not a generation is refused before any change.
mkdir -p "$rb_current"
printf '%s\n' "$rb_store/00000000000000000000000000000000-gone" >"$record"
assert_exit 1 run_rollback --latest --apply
assert_contains "$DS_STDERR" "[dotsteward] ERROR: the previous Home Manager generation is not valid: $rb_store/00000000000000000000000000000000-gone"
assert_calls
assert_eq "$rb_zsh" "$(ds_passwd_field "$USER" 7)"

printf '%s\n' "$previous" >"$record"
assert_exit 0 run_rollback --latest --dry-run
assert_contains "$DS_STDOUT" "3. Activate the recorded previous Home Manager generation: $previous"
assert_exit 0 run_rollback --latest --dry-run --json
printf '%s\n' "$DS_STDOUT" >"$DS_TEST_ROOT/plan.json"
assert_json "$DS_TEST_ROOT/plan.json" "
  .manifest == \"$current/home-path/share/dotsteward/manifest.json\"
  and .previous_generation == \"$previous\"
  and .steps[2] == { id: \"home-manager\", action: \"activate-previous\", generation: \"$previous\", links: [] }
  and .steps[3] == { id: \"restore\", files: [] }"
assert_contains "$(run_rollback --latest --dry-run)" "4. No force-linked files to restore"

# The rollback activates the previous generation and leaves the links to it.
assert_exit 0 run_rollback --latest --apply
assert_calls \
  "sudo chsh -s /bin/bash $USER" \
  "chsh -s /bin/bash $USER" \
  "activate-previous"
assert_eq "/bin/bash" "$(ds_passwd_field "$USER" 7)"
[[ -L $HOME/.zshrc ]] || ds_fail "the generation branch removed a managed link"
assert_contains "$DS_STDOUT" "[dotsteward] activating the previous Home Manager generation: $previous"

# A failing activation fails the rollback with its status.
printf '6\n' >"$DS_TEST_ROOT/previous-exit"
assert_exit 6 run_rollback --latest --apply

# Without an active generation the mirror is the manifest.
rm -f -- "$rb_hm_profile"
assert_exit 0 run_rollback --latest --dry-run --json
printf '%s\n' "$DS_STDOUT" >"$DS_TEST_ROOT/plan.json"
assert_json "$DS_TEST_ROOT/plan.json" ".manifest == \"$rb_manifest\""

# macOS: the default login shell is /bin/zsh.
python3 - "$rb_inst/workstation.toml" <<'EOF'
import sys
path = sys.argv[1]
text = open(path).read().replace('systems = ["x86_64-linux"]', 'systems = ["x86_64-linux", "aarch64-darwin"]')
open(path, "w").write(text)
EOF
jq '.system = "aarch64-darwin" | .platform = "darwin"' "$rb_manifest" \
  >"$rb_inst/.dotsteward/manifest.aarch64-darwin.json"
instance_commit "darwin"
assert_exit 0 env DOTSTEWARD_PLATFORM=darwin "$rb_fw/cli/dotsteward" --instance "$rb_inst" \
  rollback --latest --dry-run </dev/null
assert_contains "$DS_STDOUT" "1. Set the login shell of $USER to /bin/zsh"
assert_contains "$DS_STDOUT" "2. No login shell line added by this system to remove"
