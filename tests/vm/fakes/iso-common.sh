# shellcheck shell=bash
# Shared part of the fake ISO tools (xorriso -as mkisofs, genisoimage):
# fake_iso_write ARG... parses the mkisofs option subset the harness uses
# (-output FILE, -volid ID, -joliet, -rock, -quiet, input files) and writes
# FILE as "volid=ID" followed by one "== NAME" header and the bytes of each
# input file.

fake_iso_write() {
  local output="" volid="" inputs=() input
  while (($#)); do
    case $1 in
      -output | -o)
        output=$2
        shift
        ;;
      -volid | -V)
        volid=$2
        shift
        ;;
      -joliet | -rock | -quiet | -J | -r) ;;
      -*)
        printf 'fake iso tool: unsupported option %s\n' "$1" >&2
        return 1
        ;;
      *) inputs+=("$1") ;;
    esac
    shift
  done
  [[ -n $output && ${#inputs[@]} -gt 0 ]] || {
    echo 'fake iso tool: -output and at least one input are required' >&2
    return 1
  }
  {
    printf 'volid=%s\n' "$volid"
    for input in "${inputs[@]}"; do
      printf '== %s\n' "$(basename -- "$input")"
      cat -- "$input"
    done
  } >"$output"
}
