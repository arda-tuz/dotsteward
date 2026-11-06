# shellcheck shell=bash
# How bash code of the framework calls the Python package (docs/python.md).
# Commands source it next to lib.sh. It is no part of the library of component
# hooks, which is frozen (docs/hook-library.md): a hook sees these functions only
# when it sources methods.sh, and should not rely on them. It only defines functions
# and a constant.
#
#   ds_python MODULE [ARG...]  python3 -m MODULE as the commands run it: the
#                              python3 first on PATH (the package puts its
#                              own there), every source root of the package
#                              on the module path, the user site and the
#                              working directory off it, no bytecode files
#   ds_python_exec MODULE [ARG...]
#                              the same in place of this shell, for the file
#                              of a command written in Python
#   ds_internal ARG...         the internal command line of the primitives
#                              (ds_python dotsteward_cli.internal ARG...)

_DS_PYTHON_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)

ds_python() {
  PYTHONPATH=$_DS_PYTHON_ROOT/cli/python:$_DS_PYTHON_ROOT/engines/pins:$_DS_PYTHON_ROOT/engines/local-maintained-files \
    PYTHONDONTWRITEBYTECODE=1 python3 -s -P -m "$@"
}

ds_python_exec() {
  PYTHONPATH=$_DS_PYTHON_ROOT/cli/python:$_DS_PYTHON_ROOT/engines/pins:$_DS_PYTHON_ROOT/engines/local-maintained-files \
    PYTHONDONTWRITEBYTECODE=1 exec python3 -s -P -m "$@"
}

ds_internal() {
  ds_python dotsteward_cli.internal "$@"
}
