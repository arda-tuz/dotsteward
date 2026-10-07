# VM phase harness

`tests/vm/vm.sh` runs disposable Ubuntu 24.04 virtual machines on a Linux
host with QEMU and KVM, as a normal user. It serves the VM phase: a clean
install through the CLI and the agentic end-to-end test in which a coding
agent sets up a workstation with `dotsteward-init`. The VM phase starts only
after the maintainer approves it; until then the harness is checked by its
self-test, which never boots a VM.

## What a VM is

- The base is the official Ubuntu 24.04 LTS server cloud image for amd64,
  pinned in `tests/vm/image.lock` (URL, size, SHA-256). `fetch` downloads it
  over HTTPS, checks the size and then the digest, and keeps a read-only copy
  that is verified again every time a VM starts.
- Each VM is a run directory, `$DOTSTEWARD_VM_ROOT/runs/<name>` (default
  root `~/.cache/dotsteward-vm`), holding a qcow2 overlay on top of the base
  image, its own SSH client key, a pre-generated SSH host key, the cloud-init
  seed image, the serial console log and the session logs.
- cloud-init creates the user `stranger` (passwordless sudo inside the VM,
  password login disabled, the run's key as the only authorized key) and the
  marker file `/etc/dotsteward-vm`. Nothing from the host user's identity
  goes into the VM.
- The guest scripts (`tests/vm/guest/*.sh`) install software into the home
  directory and change the whole machine, so they refuse to run anywhere
  else, before any command with a side effect: `guest_require_vm` in
  `guest/common.sh` requires that marker with the text cloud-init wrote,
  a hypervisor reported by `systemd-detect-virt --vm`, and the user
  `stranger`. There is no override; run them through `vm.sh scenario`.
- Networking is QEMU user mode. The only port forward is the guest's SSH,
  bound to `127.0.0.1` on the host. Every SSH call uses the run's key, checks
  the pinned host key strictly and ignores the host's SSH configuration.
- The harness never uses sudo on the host and refuses to run as root.

## Requirements

`qemu-system-x86_64`, `qemu-img`, `ssh`, `ssh-keygen`, `git`, `python3` and
one of `xorriso`, `genisoimage`, `mkisofs` or `cloud-localds`. KVM needs read
and write access to `/dev/kvm` (membership in the `kvm` group or an ACL);
without it `up --allow-tcg` boots with software emulation, which is much
slower. A VM uses up to 20 GiB of disk and 6 GiB of memory by default.

```bash
tests/vm/vm.sh check
```

## Self-test (any time, no VM)

```bash
bash tests/vm/selftest.sh
```

It parses and lints every file under `tests/vm`, then runs the test files
with fakes for QEMU and SSH (`tests/vm/fakes`) and the harness `curl` stub.
`qemu-img`, `xorriso` and `ssh-keygen` run for real when installed. The lint
job of the `ci` workflow runs it on every push.

## Running the VM phase

Every command that downloads, boots, connects to or removes a VM needs:

```bash
export DOTSTEWARD_VM_PHASE=approved
```

Clean install (unattended):

```bash
tests/vm/vm.sh up --name clean
tests/vm/vm.sh scenario clean-install --name clean
tests/vm/vm.sh destroy --name clean
```

`scenario` first pushes the committed `HEAD` of this checkout (or `--ref`,
or `--source DIR`) into the VM as `~/dotsteward-src`, then runs
`tests/vm/guest/clean-install.sh` there: the verified Nix install of
stage-0, `dotsteward init` of a template instance with all six catalog
components from that checkout, `./bootstrap.sh` with the fresh profile,
`dotsteward e2e`, and `./rollback.sh --latest --apply`. Uncommitted changes
are not pushed. The session is logged in `runs/<name>/logs/`.

Agentic end-to-end test, one fresh VM per agent:

```bash
tests/vm/vm.sh up --name claude
tests/vm/vm.sh scenario agent-prepare --name claude -- --agent claude
tests/vm/vm.sh ssh --name claude
# in the VM: start the agent, log in, install the dotsteward plugin from the
# local marketplace in ~/dotsteward-src, ask for a new workstation
tests/vm/vm.sh scenario agent-verify --name claude --no-push
tests/vm/vm.sh destroy --name claude
```

Then the same with `--name codex` and `--agent codex`. `agent-prepare`
installs the agent with its vendor's method for Linux, creates an empty bare
repository at `~/remotes/workstation.git` as the instance's remote (plain
`dotsteward e2e` needs a pushed origin), and prints the exact steps and a
suggested request. `agent-verify` checks the instance the agent created
(initialized, committed, clean, pushed to origin) and runs `dotsteward e2e`
for the instance's current profile (as `dotsteward context` reports it), or
for the profile given with `--profile`.

## Commands

| Command | Approval | Purpose |
| --- | --- | --- |
| `check` | no | host tools, KVM access, free space |
| `plan [run options]` | no | the files and QEMU command line `up` would use |
| `status [--name N]` | no | state of one VM or of all |
| `pin [--write]` | no | resolve the current release image; `--write` updates `image.lock` |
| `scenario --list` | no | the scenarios (`tests/vm/guest/*.sh`) |
| `fetch` | yes | download and verify the base image |
| `up [run options]` | yes | create or restart a VM and wait for SSH and cloud-init |
| `ssh [--name N] [-- CMD]` | yes | a shell, or one command with its exit status |
| `push [--name N] [--source DIR] [--ref REV]` | yes | ship a committed revision to `~/dotsteward-src` |
| `scenario NAME [...] [-- ARGS]` | yes | push, then run the guest script |
| `down [--name N] [--force]` | yes | power off (forced: stop QEMU at once) |
| `destroy [--name N]` | yes | stop and delete the run directory |

Run options: `--name`, `--memory MIB`, `--cpus N`, `--disk SIZE`,
`--ssh-port PORT`, `--boot-timeout S`, `--allow-tcg`. A stopped VM restarts
with its recorded settings and disk. When the boot times out the VM keeps
running for inspection of `runs/<name>/console.log`.

## Troubleshooting

- `KVM is not usable`: grant access to `/dev/kvm`, or pass `--allow-tcg`.
- `not reachable over SSH`: read the console tail printed with the error,
  then `tests/vm/vm.sh down --name N`.
- `cloud-init failed`: `tests/vm/vm.sh ssh --name N -- cloud-init status --long`.
- The pinned image disappeared from the mirror (Ubuntu keeps only recent
  serials): `tests/vm/vm.sh pin --write`, review and commit `image.lock`.
