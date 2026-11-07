#!/usr/bin/env bash
# summary: Fake E2E of the upgrade tests: its record, and red on request
#
# $UP_CONTROL/e2e-red-once: this run is red, with the findings in the file (one id per line).
# $UP_CONTROL/e2e-red: every run is. $UP_CONTROL/drop-network-after-e2e: the network ends here.
set -euo pipefail
printf 'e2e %s\n' "$*" >>"$UP_LOG"
root=$DOTSTEWARD_INSTANCE
repo_checks=true
case " $* " in
  *" --skip-repo-checks "*) repo_checks=false ;;
esac
red=
if [[ -e $UP_CONTROL/e2e-red-once ]]; then
  red=$UP_CONTROL/e2e-red-once
elif [[ -e $UP_CONTROL/e2e-red ]]; then
  red=$UP_CONTROL/e2e-red
fi
result=passed
findings='[]'
if [[ -n $red ]]; then
  result=failed
  findings=$(jq -Rn '[inputs | {step: ., path: "", code: "hook-failed", message: "red on request"}]' <"$red")
  [[ $red != "$UP_CONTROL/e2e-red-once" ]] || rm -f -- "$red"
fi
mkdir -p "$DOTSTEWARD_STATE_ROOT/update"
generation=$(jq -r '.generation // ""' "$DOTSTEWARD_STATE_ROOT/current/activation.json" 2>/dev/null || true)
profile=$(jq -r '.profile // ""' "$DOTSTEWARD_STATE_ROOT/current/activation.json" 2>/dev/null || true)
jq -n --arg result "$result" --arg tree "$(git -C "$root" rev-parse 'HEAD^{tree}')" --arg head "$(git -C "$root" rev-parse HEAD)" \
  --arg generation "$generation" --arg profile "$profile" --arg root "$root" --argjson repo "$repo_checks" '{
  schema_version: "1.0", result: $result, tree_oid: $tree, head_oid: $head, generation: $generation,
  profile: $profile, framework_override: null, repo_checks: $repo, findings: 0, root: $root,
  recorded_at: "2026-01-01T00:00:00Z"}' >"$DOTSTEWARD_STATE_ROOT/update/e2e.json"
if [[ -e $UP_CONTROL/drop-network-after-e2e ]]; then
  : >"$UP_CONTROL/network-down"
fi
jq -n --arg result "$result" --argjson findings "$findings" '{result: $result, findings: $findings}'
[[ $result == passed ]]
