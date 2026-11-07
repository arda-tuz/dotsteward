#!/usr/bin/env bash
# summary: Fake pins of the upgrade tests: check passes, apply moves what $UP_CONTROL/moves names
#
# `pins apply` appends a line to versions.lock.json for each object of the JSON array
# $UP_CONTROL/moves, once per id and version, and answers as the real writer. Its exit status is
# $UP_CONTROL/pins-status when that exists. The writer itself has tests/engines/pins/apply.
set -euo pipefail
printf 'pins %s\n' "$*" >>"$UP_LOG"
root=$DOTSTEWARD_INSTANCE
command=
out=
skips=()
while (($#)); do
  case $1 in
    check | latest | apply | sync)
      command=$1
      ;;
    --out)
      out=$2
      shift
      ;;
    --skip)
      skips+=("$2")
      shift
      ;;
  esac
  shift
done
case $command in
  latest)
    rows=$UP_CONTROL/latest-rows
    if [[ -e $rows ]]; then
      cp -- "$rows" "$out"
    else
      jq -n '{schema_version: "1.0", researched_at: "2026-01-01T00:00:00Z", items: []}' >"$out"
    fi
    if [[ -e $UP_CONTROL/latest-status ]]; then
      exit "$(<"$UP_CONTROL/latest-status")"
    fi
    ;;
  apply)
    if [[ -e $UP_CONTROL/pins-garbage ]]; then
      printf 'not json\n'
      exit 1
    fi
    moved='[]'
    if [[ -e $UP_CONTROL/moves ]]; then
      for move in $(jq -c '.[]' "$UP_CONTROL/moves"); do
        id=$(jq -r .id <<<"$move")
        for skip in ${skips[@]+"${skips[@]}"}; do
          # shellcheck disable=SC2053 # the pattern is the point
          [[ $id != $skip ]] || continue 2
        done
        lock=$root/versions.lock.json
        if ! jq -e --argjson move "$move" '.[$move.id] == $move.to' "$lock" >/dev/null; then
          jq --argjson move "$move" '.[$move.id] = $move.to' "$lock" >"$lock.new"
          mv -- "$lock.new" "$lock"
          moved=$(jq -c --argjson move "$move" '. + [$move]' <<<"$moved")
        fi
      done
    fi
    groups='[]'
    if [[ -e $UP_CONTROL/pins-status && $(<"$UP_CONTROL/pins-status") == 1 ]]; then
      groups='[{"group": "npm:example", "outcome": "failed", "ids": ["example.broken"], "error": "asset 404"}]'
    fi
    jq -n --argjson moved "$moved" --argjson groups "$groups" '{
      moved: $moved, groups: $groups, lines: [], items: [],
      framework_moved: ([$moved[] | select(.group == "framework")] | length > 0),
      flake_inputs_moved: [$moved[] | select(.id | startswith("flake_inputs.")) | .id],
      status: "ok", exit_code: 0}'
    if [[ -e $UP_CONTROL/pins-status ]]; then
      exit "$(<"$UP_CONTROL/pins-status")"
    fi
    ;;
esac
