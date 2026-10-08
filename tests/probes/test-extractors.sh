# shellcheck shell=bash
# shellcheck disable=SC2154 # DS_* variables come from tests/lib/harness.sh
# Version extractors: first-line, field:<label>, prefix:<text>,
# printf-vd and regex:<re>. A version probe compares the extracted standard
# output with the expected value as strings; the probe's exit status and
# standard error are ignored. When nothing can be extracted the message says
# "found nothing" and shows the first non-empty output line.
# shellcheck source=tests/probes/helpers.sh
source "$DS_REPO_ROOT/tests/probes/helpers.sh"

ds_use_stubs example-app
manifest=$DS_TEST_ROOT/manifest.json
expected='"versions:agent_tools.example-app.version"'

# check_version EXTRACT OUTPUT [MESSAGE]: the stub prints OUTPUT for
# --version; without MESSAGE the probe must pass, otherwise it must fail
# with that error line.
check_version() {
  local extract=$1 output=$2 message=${3:-}
  write_manifest "$manifest" \
    "$(probe example-app example-app version extract "$(jq -cn --arg e "$extract" '$e')" expected "$expected")"
  ds_stub_set example-app version "$output"
  if [[ -z $message ]]; then
    assert_exit 0 run_manifest "$manifest"
    assert_eq "[dotsteward] probes passed: 1 version, 0 presence, 0 features (profile main)" "$DS_STDOUT" \
      "$extract on [$output]"
  else
    assert_exit 1 run_manifest "$manifest"
    assert_eq "[dotsteward] ERROR: $message" "$DS_STDERR" "$extract on [$output]"
  fi
}

# first-line: the whole first line.
check_version first-line "1.2.3"
check_version first-line $'1.2.3\nbuilt from source'
check_version first-line "1.2.4" "example-app version mismatch: expected 1.2.3, found 1.2.4"
check_version first-line "example-app 1.2.3" \
  "example-app version mismatch: expected 1.2.3, found example-app 1.2.3"
check_version first-line $'\n1.2.3' "example-app version mismatch: expected 1.2.3, found nothing (output: 1.2.3)"

# field:<label>: the second field of the first line whose first field is the
# label.
check_version "field:version:" $'Example App\nversion: 1.2.3\nlicense: none'
check_version "field:version:" $'Example App\n  version:   1.2.3   extra'
check_version "field:version:" $'Example App\nversion: 1.2.4' \
  "example-app version mismatch: expected 1.2.3, found 1.2.4"
check_version "field:version:" $'Example App\nrelease: 1.2.3' \
  "example-app version mismatch: expected 1.2.3, found nothing (output: Example App)"
check_version "field:version:" $'Example App\nversion:' \
  "example-app version mismatch: expected 1.2.3, found nothing (output: Example App)"
# Only the first labelled line counts, and the label is compared as text
# (never as a number).
check_version "field:version:" $'version:\nversion: 1.2.3' \
  "example-app version mismatch: expected 1.2.3, found nothing (output: version:)"
check_version "field:1" $'1.0 9.9.9\n1 1.2.3'
# The label is literal text, not a pattern or an escape sequence.
check_version 'field:v\t*' $'v\\t* 1.2.3'
check_version 'field:v\t*' $'version 1.2.3' \
  "example-app version mismatch: expected 1.2.3, found nothing (output: version 1.2.3)"

# prefix:<text>: the first line without the prefix; a line without the
# prefix never passes, even when it equals the expected value.
check_version "prefix:example-app " "example-app 1.2.3"
check_version "prefix:example-app " "example-app 1.2.4" \
  "example-app version mismatch: expected 1.2.3, found 1.2.4"
check_version "prefix:example-app " "1.2.3" \
  "example-app version mismatch: expected 1.2.3, found nothing (output: 1.2.3)"
check_version "prefix:example-app " "other-app 1.2.3" \
  "example-app version mismatch: expected 1.2.3, found nothing (output: other-app 1.2.3)"
check_version "prefix:[*] " "[*] 1.2.3"

# printf-vd: the dotted-decimal version (the %vd form), a leading "v"
# dropped, wherever it stands in the output.
check_version printf-vd "1.2.3"
check_version printf-vd "v1.2.3"
check_version printf-vd \
  $'\nThis is example-app 1, version 2, subversion 3 (v1.2.3) built for x86_64-linux\n\nCopyright'
check_version printf-vd "v1.2.4" "example-app version mismatch: expected 1.2.3, found 1.2.4"
check_version printf-vd "build1.2.3" \
  "example-app version mismatch: expected 1.2.3, found nothing (output: build1.2.3)"
check_version printf-vd "version 7" \
  "example-app version mismatch: expected 1.2.3, found nothing (output: version 7)"

# regex:<re>: the first matching line; the first capture group when the
# expression has one, otherwise the whole match.
check_version "regex:release ([0-9.]+)" $'example-app\nrelease 1.2.3 (stable)'
check_version "regex:[0-9]+[.][0-9]+[.][0-9]+" "example-app 1.2.3-stable"
check_version "regex:^example-app ([0-9.]+)$" $'example-app 9.9.9 beta\nexample-app 1.2.3'
check_version "regex:release ([0-9.]+)" "release 1.2.4" \
  "example-app version mismatch: expected 1.2.3, found 1.2.4"
check_version "regex:release ([0-9.]+)" "example-app 1.2.3" \
  "example-app version mismatch: expected 1.2.3, found nothing (output: example-app 1.2.3)"

# The probe's exit status is ignored; only standard output is compared.
write_manifest "$manifest" \
  "$(probe example-app example-app version extract '"first-line"' expected "$expected")"
ds_stub_route example-app '--version' --exit 3 --stdout "1.2.3" --stderr "a warning" --times 1
assert_exit 0 run_manifest "$manifest"
assert_eq "[dotsteward] probes passed: 1 version, 0 presence, 0 features (profile main)" "$DS_STDOUT"
assert_contains "$DS_STDERR" "a warning"
ds_stub_route example-app '--version' --stdout "" --stderr "1.2.3" --times 1
assert_exit 1 run_manifest "$manifest"
assert_eq "1.2.3" "${DS_STDERR%%$'\n'*}"
assert_eq "[dotsteward] ERROR: example-app version mismatch: expected 1.2.3, found nothing" "${DS_STDERR#*$'\n'}"
