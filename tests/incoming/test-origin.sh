# shellcheck shell=bash
# shellcheck disable=SC2154 # variables come from the harness and the helpers
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose
# Who made a change: the trail in the commit. No trail is an unknown machine, the trail of
# this machine and a commit not published yet are this machine's own: no question.
# shellcheck source=tests/incoming/helpers.sh
source "$DS_REPO_ROOT/tests/incoming/helpers.sh"

machine_up laptop1
machine_up laptop2

# A commit by hand, somewhere: it comes with no name.
hand_skill laptop1 manual
by_hand laptop1 "feat: a skill by hand"
up_to_date laptop2
assert_exit 0 ds laptop2 incoming list --json
assert_json - '.items[0].id == "skill:manual" and .items[0].by == null' <<<"$DS_STDOUT"
assert_exit 0 ds laptop2 incoming list
assert_contains "$DS_STDOUT" 'skill manual (new) - an unknown machine'
assert_exit 0 ds laptop2 incoming answer skill:manual --install

# A skill this machine committed and has not published: its own, `rebuild` installs it.
up_to_date laptop1
hand_skill laptop2 mine
git -C "$(clone_of laptop2)" add -A
git -C "$(clone_of laptop2)" commit -q -m "feat: a skill of this machine"
assert_eq '' "$(waiting laptop2)"
assert_exit 0 agents laptop2 install --skip-validation
[[ -f $(home_of laptop2)/.agents/skills/mine/SKILL.md ]] || ds_fail "the own commit was not installed"
assert_eq "$(jq -r '.skills[] | select(.name == "mine") | .directory_sha256' "$(clone_of laptop2)/agent/skills.lock.json")" \
  "$(base laptop2 mine)"

# It stays known once it is published.
git -C "$(clone_of laptop2)" push -q origin main
assert_eq '' "$(waiting laptop2)"

# A commit that names this machine is its own too, without its copy: a reinstall of the
# state on the same name, for instance. The copy comes with the next install.
up_to_date laptop1
assert_eq 'skill:mine' "$(waiting laptop1)"
hand_skill laptop1 signed
git -C "$(clone_of laptop1)" add -A
git -C "$(clone_of laptop1)" commit -q -m $'feat: signed\n\nDotsteward-Machine: laptop1'
git -C "$(clone_of laptop1)" push -q origin main
assert_eq 'skill:mine' "$(waiting laptop1)"
assert_exit 0 agents laptop1 install --skip-validation
[[ -f $(home_of laptop1)/.agents/skills/signed/SKILL.md ]] || ds_fail "the signed commit was not installed"
assert_eq 'skill:mine' "$(waiting laptop1)"

# The other machine reads the name from the same line.
up_to_date laptop2
assert_exit 0 ds laptop2 incoming list --json
assert_json - '.items[0].id == "skill:signed" and .items[0].by == "laptop1"' <<<"$DS_STDOUT"
