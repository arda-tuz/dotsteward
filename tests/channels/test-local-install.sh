# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# tests/channels/local-install.sh over stand-ins of claude, codex and gh
# that install the plugin and the skill into the channel's HOME the way the
# real tools do, so every channel passes. Its cleanup never changes the
# outcome of the run: a late writer (a process a tool left behind that
# still writes below the work directory while it is removed, like a
# detached git maintenance run) does not turn a green run red, and the
# directory is gone once the writer stops; a red run stays red; a directory
# that cannot be removed (a read-only one) is reported and the run stays
# green. The HOME of every channel turns off git's automatic maintenance and
# its detached gc.
#
# The real installs run in the channels workflow; this test needs only bash,
# git and jq.

script=$DS_REPO_ROOT/tests/channels/local-install.sh
plugin=$DS_REPO_ROOT/plugins/dotsteward
version=$(<"$DS_REPO_ROOT/VERSION")
bin=$DS_TEST_ROOT/bin
state=$DS_TEST_ROOT/stand-ins
mkdir -p "$bin" "$state"

# The stand-ins start with the running bash (the build sandbox has no
# /usr/bin/env). Each records git's maintenance settings in the channel's
# HOME when it adds a marketplace or lists the skills.
# shellcheck disable=SC2016 # the command is written into the stand-ins unexpanded
record_git='printf "%s %s\n" "$(git config --global --get maintenance.auto || echo unset)" "$(git config --global --get gc.autoDetach || echo unset)" >>'"'$state/git-config'"

cat >"$bin/claude" <<STUB
#!$BASH
set -euo pipefail
cache=\$HOME/.claude/plugins/cache/dotsteward/dotsteward/$version
case "\$*" in
  'plugin marketplace add '*) $record_git ;;
  'plugin install dotsteward@dotsteward') mkdir -p "\$cache" && cp -R '$plugin/.' "\$cache/" ;;
  'plugin list --json')
    printf '[{"id":"dotsteward@dotsteward","version":"%s","enabled":true,"scope":"user","installPath":"%s"}]\n' \\
      '$version' "\$cache" ;;
  *) echo "claude stand-in: unexpected arguments: \$*" >&2; exit 64 ;;
esac
STUB

cat >"$bin/codex" <<STUB
#!$BASH
set -euo pipefail
cache=\$HOME/.codex/plugins/cache/dotsteward/dotsteward/$version
case "\$*" in
  'plugin marketplace add '*) $record_git ;;
  'plugin add dotsteward@dotsteward')
    [[ ! -f '$state/codex-fails' ]] || exit 1
    mkdir -p "\$cache" && cp -R '$plugin/.' "\$cache/" ;;
  'plugin list --json')
    printf '{"installed":[{"pluginId":"dotsteward@dotsteward","version":"%s","installed":true,"enabled":true}]}\n' '$version' ;;
  *) echo "codex stand-in: unexpected arguments: \$*" >&2; exit 64 ;;
esac
STUB

# gh: the skills installer. Installing for codex, the last step of a run,
# starts the late writer when $state/writer-us holds how many microseconds
# it writes: a new file in a directory below the channel's TMPDIR about
# every 100 microseconds (the clock is read without a subshell, so it keeps
# up), until the time is over or the directory is gone; the stand-in
# returns once the writer wrote its first file. With $state/read-only, it
# leaves a read-only directory with a file below that TMPDIR.
cat >"$bin/gh" <<STUB
#!$BASH
set -euo pipefail
[[ \$1 == skill && \$2 == install ]] || { echo "gh stand-in: unexpected arguments: \$*" >&2; exit 64; }
[[ \$3 != --help ]] || exit 0
agent=""
named=0
for arg in "\$@"; do
  [[ \$arg != dotsteward-init ]] || named=1
done
while ((\$#)); do
  [[ \$1 != --agent ]] || agent=\$2
  shift
done
if ((!named)); then
  $record_git
  printf 'dotsteward/dotsteward-init\tSets up a dotsteward instance\n'
  exit 0
fi
case \$agent in
  claude-code) dir=\$HOME/.claude/skills/dotsteward-init ;;
  codex) dir=\$HOME/.agents/skills/dotsteward-init ;;
  *) echo "gh stand-in: unknown agent: \$agent" >&2; exit 64 ;;
esac
mkdir -p "\$dir" && cp -R '$plugin/skills/dotsteward-init/.' "\$dir/"
[[ \$agent == codex ]] || exit 0
if [[ -f '$state/writer-us' ]]; then
  late=\$TMPDIR/late
  mkdir -p "\$late"
  (
    end=\$((\${EPOCHREALTIME//[!0-9]/} + \$(<'$state/writer-us')))
    n=0
    while ((\${EPOCHREALTIME//[!0-9]/} < end)); do
      : 2>/dev/null >"\$late/\$n" || break
      n=\$((n + 1))
      pause=\$((\${EPOCHREALTIME//[!0-9]/} + 100))
      while ((\${EPOCHREALTIME//[!0-9]/} < pause)); do :; done
    done
  ) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "\$!" >'$state/writer.pid'
  tries=0
  while [[ ! -e \$late/0 ]] && ((tries < 500)); do
    sleep 0.01
    tries=\$((tries + 1))
  done
fi
if [[ -f '$state/read-only' ]]; then
  mkdir -p "\$TMPDIR/read-only"
  : >"\$TMPDIR/read-only/file"
  chmod 0555 "\$TMPDIR/read-only"
fi
STUB
chmod 0755 "$bin/claude" "$bin/codex" "$bin/gh"

# run_install: the script from the checkout over the stand-ins, with a
# TMPDIR of its own (the work directory is created below it).
tmp=$DS_TEST_ROOT/channels-tmp
run_install() {
  mkdir -p "$tmp"
  PATH=$bin:$PATH TMPDIR=$tmp bash "$script"
}

# leftovers: what the run left in its TMPDIR.
leftovers() {
  find "$tmp" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | paste -sd' ' -
}

# stop_writer: ends a late writer that is still running.
stop_writer() {
  local pid tries=0
  [[ -f $state/writer.pid ]] || return 0
  pid=$(<"$state/writer.pid")
  rm -f -- "$state/writer.pid"
  kill "$pid" 2>/dev/null || return 0
  while kill -0 "$pid" 2>/dev/null && ((tries < 100)); do
    sleep 0.1
    tries=$((tries + 1))
  done
}
ds_defer stop_writer
# writable_tmp: makes a read-only directory removable again.
writable_tmp() {
  [[ ! -d $tmp ]] || chmod -R u+w -- "$tmp"
}
ds_defer writable_tmp

# A green run.
assert_exit 0 run_install
assert_contains "$DS_STDERR" "[dotsteward] channels: all channels installed dotsteward-init $version"
for channel in claude-code codex skills; do
  assert_contains "$DS_STDERR" "[dotsteward] channels: $channel: ok"
done
assert_eq "" "$(leftovers)" "the work directory is removed"

# A late writer that stops after 1.5 seconds: the run stays green, and the
# work directory is removed once the writer stopped.
printf '1500000\n' >"$state/writer-us"
assert_exit 0 run_install
assert_contains "$DS_STDERR" "[dotsteward] channels: all channels installed dotsteward-init $version"
assert_not_contains "$DS_STDERR" "Directory not empty"
assert_eq "" "$(leftovers)" "the work directory is removed after the late writer"

# No automatic git maintenance in the HOME of any channel of the two runs.
assert_eq 6 "$(wc -l <"$state/git-config" | tr -d ' ')" "git settings recorded by every channel"
assert_eq "false false" "$(sort -u "$state/git-config")" "maintenance.auto and gc.autoDetach in each channel's HOME"

# A red run stays red, with the late writer too.
: >"$state/codex-fails"
assert_exit 1 run_install
assert_contains "$DS_STDERR" "[dotsteward] FAIL: channels codex: codex plugin add dotsteward@dotsteward failed"
assert_contains "$DS_STDERR" "[dotsteward] ERROR: channels: 1 check(s) failed"
assert_eq "" "$(leftovers)" "the work directory of a red run is removed"
rm -f -- "$state/codex-fails"

# A work directory that cannot be removed (a read-only directory in it):
# it stays and is reported, and the run stays green.
rm -f -- "$state/writer-us"
: >"$state/read-only"
assert_exit 0 run_install
assert_contains "$DS_STDERR" "[dotsteward] channels: all channels installed dotsteward-init $version"
work=$(leftovers)
[[ $work == tmp.* ]] || ds_fail "the work directory that cannot be removed was not left behind: [$work]"
assert_contains "$DS_STDERR" "[dotsteward] WARNING: channels: $tmp/$work could not be removed"
writable_tmp
rm -rf -- "${tmp:?}/$work"
