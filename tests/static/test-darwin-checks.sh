# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# The darwin checks and the macOS CI (decision K13: macOS is tested on
# release tags and nightly). checks.aarch64-darwin of nix/outputs.nix is the
# list darwinChecks of existing checks: not empty, each one a
# nix/checks/<name>.nix, none named twice, and none that builds an
# x86_64-linux derivation or is meant for Linux only. The workflow
# .github/workflows/macos-smoke.yml runs on release tags (v*), on a nightly
# schedule and on demand, never on branch pushes, and has a job on a macOS
# runner that runs `nix flake check`, which builds the checks of the
# runner's system, aarch64-darwin.

outputs=$DS_REPO_ROOT/nix/outputs.nix
workflow=$DS_REPO_ROOT/.github/workflows/macos-smoke.yml
[[ -f $outputs ]] || ds_fail "missing nix/outputs.nix"
[[ -f $workflow ]] || ds_fail "missing .github/workflows/macos-smoke.yml"

# --- checks.aarch64-darwin ---------------------------------------------------------

# The names of the darwinChecks list (one quoted name per line).
mapfile -t names < <(awk '
  /^  darwinChecks = \[/ { open = 1; next }
  open && /^  \];/ { exit }
  open && match($0, /"[a-z0-9-]+"/) { print substr($0, RSTART + 1, RLENGTH - 2) }
' "$outputs")
((${#names[@]})) || ds_fail "nix/outputs.nix has no darwinChecks list, or it is empty"
grep -qE '^    aarch64-darwin = lib\.getAttrs darwinChecks \(checksFor "aarch64-darwin"\);' "$outputs" ||
  ds_fail "checks.aarch64-darwin is not the darwinChecks of checksFor \"aarch64-darwin\""
assert_eq "${#names[@]}" "$(printf '%s\n' "${names[@]}" | LC_ALL=C sort -u | wc -l)" "darwin checks named twice"
for name in "${names[@]}"; do
  check=$DS_REPO_ROOT/nix/checks/$name.nix
  [[ -f $check ]] || ds_fail "darwinChecks names $name, which is no nix/checks/$name.nix"
  # Comments may mention Linux; the code of a darwin check builds nothing
  # for it.
  if grep -v '^[[:space:]]*#' "$check" | grep -qE 'x86_64-linux|platforms\.linux|isLinux'; then
    ds_fail "darwinChecks names $name, whose definition needs Linux"
  fi
done

# --- the macOS workflow -----------------------------------------------------------

# The trigger block (the lines below `on:` up to the next top-level key).
triggers=$(awk '/^on:/ { open = 1; next } open && /^[A-Za-z]/ { exit } open { print }' "$workflow")
grep -qE '^  workflow_dispatch:' <<<"$triggers" || ds_fail "macos-smoke.yml cannot run on demand (workflow_dispatch)"
push=$(awk '/^  push:/ { open = 1; next } open && /^  [A-Za-z]/ { exit } open { print }' <<<"$triggers")
if ! grep -qE '^    tags:' <<<"$push" || ! grep -qE '^      - "v\*"' <<<"$push"; then
  ds_fail "macos-smoke.yml does not run on the release tags (push: tags: \"v*\")"
fi
if grep -qE '^    branches' <<<"$push"; then
  ds_fail "macos-smoke.yml runs on branch pushes; only tags, the schedule and dispatches run it"
fi
if ! grep -qE '^  schedule:' <<<"$triggers" || ! grep -qE '^    - cron: "[0-9]{1,2} [0-9]{1,2} \* \* \*"' <<<"$triggers"; then
  ds_fail "macos-smoke.yml has no nightly schedule (a daily cron)"
fi

# A job on a macOS runner runs `nix flake check`.
jobs=$(awk '
  /^jobs:/ { open = 1; next }
  open && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); next }
  open && job != "" && /runs-on: macos-/ { mac[job] = 1 }
  open && job != "" && /nix .*flake check/ { check[job] = 1 }
  END { for (job in mac) if (check[job]) print job }
' "$workflow")
[[ -n $jobs ]] || ds_fail "no job of macos-smoke.yml runs nix flake check on a macOS runner"
# The smoke test of a real activation stays.
grep -qF 'bash tests/ci/macos-smoke.sh' "$workflow" || ds_fail "macos-smoke.yml no longer runs tests/ci/macos-smoke.sh"
