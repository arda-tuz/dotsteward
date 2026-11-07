#!/usr/bin/env bash
# summary: Fake preflight of the apply tests: the fast route, or the adaptive one on request
#
# $UP_CONTROL/preflight-adaptive: the adaptive route (a warning, exit 3).
set -euo pipefail
printf 'preflight %s\n' "$*" >>"$UP_LOG"
profile=""
while (($#)); do
  [[ $1 != --profile ]] || profile=$2
  shift
done
route=fast
[[ ! -e $UP_CONTROL/preflight-adaptive ]] || route=adaptive
jq -n --arg profile "$profile" --arg route "$route" '{
  schema_version: "1.0", profile: $profile, route: $route, fast_path: ($route == "fast"),
  platform: {os_id: "ubuntu", os_version: "24.04", architecture: "x86_64", desktop: null},
  writes_performed: false}'
if [[ $route == adaptive ]]; then
  printf '[dotsteward] WARNING: this machine is not on the fast path of the instance\n' >&2
  exit 3
fi
