#!/bin/sh
# Example status line: the working directory relative to $HOME.
printf '%s\n' "${PWD#"$HOME"}"
