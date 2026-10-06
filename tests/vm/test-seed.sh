# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The cloud-init NoCloud seed of a run: a generic guest user reachable only
# with the run's own key, a pre-generated guest host key (so the host checks
# it strictly), the guest marker file, nothing from the host's identity,
# private modes, and the ISO tool choice (xorriso by default, override by
# DOTSTEWARD_VM_ISO_TOOL).

# shellcheck source=tests/vm/testlib.sh
source "$DS_REPO_ROOT/tests/vm/testlib.sh"
vm_test_init
vm_fake_image

assert_exit 0 "$VM_SH" up
run=$(vm_run_dir)
user_data=$run/seed/user-data
meta_data=$run/seed/meta-data
[[ -f $user_data && -f $meta_data ]] || ds_fail "seed files are missing"
ud=$(<"$user_data")
md=$(<"$meta_data")

assert_eq '#cloud-config' "$(head -n 1 "$user_data")"
for expected in \
  'hostname: dotsteward-vm' \
  '  - name: stranger' \
  '    shell: /bin/bash' \
  '    groups: [sudo]' \
  'ssh_pwauth: false' \
  'disable_root: true' \
  'ssh_deletekeys: true' \
  'ssh_genkeytypes: []' \
  '  - path: /etc/dotsteward-vm' \
  '  - path: /etc/sudoers.d/90-dotsteward-vm' \
  '    permissions: "0440"' \
  '      Defaults:stranger !authenticate' \
  '      stranger ALL=(ALL:ALL) ALL'; do
  assert_contains "$ud" "$expected"
done

# The run's client key is the only authorized key; its private half stays
# on the host.
client_pub=$(<"$run/id_ed25519.pub")
assert_contains "$client_pub" 'ssh-ed25519 '
assert_contains "$ud" "      - $client_pub"
assert_eq 1 "$(grep -c 'ssh-ed25519 ' <<<"$(sed -n '/ssh_authorized_keys:/,/^[a-z]/p' "$user_data")")" \
  "exactly one authorized key"
# (the first body lines are a header every OpenSSH key shares; line 5
# holds private key material)
client_secret_line=$(sed -n 5p "$run/id_ed25519")
[[ ${#client_secret_line} -ge 40 ]] || ds_fail "unexpected private key layout"
assert_not_contains "$ud" "$client_secret_line" "the client private key leaked into the seed"

# The guest host key is pre-generated and pinned in known_hosts.
host_pub=$(cut -d' ' -f1,2 "$run/host_ed25519.pub")
assert_contains "$ud" "  ed25519_public: $host_pub"
while IFS= read -r line; do
  assert_contains "$ud" "    $line" "host private key line"
done <"$run/host_ed25519"
assert_eq "dotsteward-vm-default $host_pub" "$(<"$run/known_hosts")"

# Nothing of the host identity reaches the guest.
assert_not_contains "$ud" "$HOME"
assert_not_contains "$ud" "$DS_TEST_IDENTITY_NAME"
assert_not_contains "$ud" "$DS_TEST_ROOT"
assert_not_contains "$md" "$DS_TEST_IDENTITY_NAME"

[[ $md =~ (^|$'\n')instance-id:\ dotsteward-default-[0-9]{8}T[0-9]{6}Z($'\n'|$) ]] ||
  ds_fail "unexpected meta-data instance-id: [$md]"
assert_contains "$md" 'local-hostname: dotsteward-vm'

# Private modes for everything that holds a key.
assert_file_mode "$run" 700
assert_file_mode "$run/seed" 700
assert_file_mode "$run/id_ed25519" 600
assert_file_mode "$run/host_ed25519" 600
assert_file_mode "$user_data" 600
assert_file_mode "$run/seed.iso" 600

# xorriso builds the seed with the NoCloud volume id.
assert_call_count 1 xorriso '-as mkisofs *-volid cidata *'
iso=$(<"$run/seed.iso")
assert_contains "$iso" 'volid=cidata'
assert_contains "$iso" '== user-data'
assert_contains "$iso" '== meta-data'
assert_call_count 0 genisoimage

# Structure check with a YAML parser when one is available.
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$user_data" "$client_pub" "$host_pub" <<'PY' || ds_fail "user-data structure check failed"
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
user = data["users"][0]
assert user["name"] == "stranger", user
assert user["ssh_authorized_keys"] == [sys.argv[2]], user
assert data["ssh_pwauth"] is False
assert data["ssh_keys"]["ed25519_public"] == sys.argv[3]
assert data["ssh_keys"]["ed25519_private"].endswith("\n")
files = {entry["path"]: entry for entry in data["write_files"]}
assert set(files) == {"/etc/dotsteward-vm", "/etc/sudoers.d/90-dotsteward-vm"}, files
sudoers = files["/etc/sudoers.d/90-dotsteward-vm"]
assert sudoers["permissions"] == "0440"
assert sudoers["content"] == "Defaults:stranger !authenticate\nstranger ALL=(ALL:ALL) ALL\n", sudoers
PY
else
  printf 'note: PyYAML not available, structural user-data check skipped\n'
fi

# DOTSTEWARD_VM_ISO_TOOL selects another tool; unknown names are refused.
assert_exit 0 env DOTSTEWARD_VM_ISO_TOOL=genisoimage "$VM_SH" up --name second
assert_call_count 1 genisoimage '*-volid cidata *'
assert_contains "$(<"$(vm_run_dir second)/seed.iso")" 'volid=cidata'
assert_exit 1 env DOTSTEWARD_VM_ISO_TOOL=mkfs.vfat "$VM_SH" up --name third
assert_contains "$DS_STDERR" 'DOTSTEWARD_VM_ISO_TOOL'
assert_exit 1 env DOTSTEWARD_VM_ISO_TOOL="$DS_TEST_ROOT/missing/cloud-localds" "$VM_SH" up --name fourth
assert_contains "$DS_STDERR" 'not found'
[[ ! -e $(vm_run_dir third) && ! -e $(vm_run_dir fourth) ]] ||
  ds_fail "a refused ISO tool left a run directory"

# Two runs never share keys.
[[ $(<"$run/id_ed25519.pub") != "$(<"$(vm_run_dir second)/id_ed25519.pub")" ]] ||
  ds_fail "two runs share a client key"
