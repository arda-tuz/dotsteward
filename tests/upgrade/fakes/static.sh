#!/usr/bin/env bash
# summary: Fake static of the upgrade tests
printf 'static %s\n' "$*" >>"$UP_LOG"
[[ ! -e $UP_CONTROL/static-red ]]
