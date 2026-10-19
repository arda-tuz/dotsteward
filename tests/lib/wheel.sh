# shellcheck shell=bash
# Synthetic Python wheels and an offline pip for tests of the pypi method.
# Source it from a test (after the harness):
#   source "$DS_REPO_ROOT/tests/lib/wheel.sh"
#
# Sourcing points pip at the directory DS_WHEELS (created in DS_TEST_ROOT)
# through PIP_NO_INDEX and PIP_FIND_LINKS, so no index is ever asked, and
# points the Nix store check of the method at an empty directory
# (NIX_STORE_DIR), since the interpreter of the test environment lives in
# the Nix store.
#
#   ds_make_wheel NAME VERSION  a pure-Python wheel in DS_WHEELS whose console
#                               script NAME prints "NAME VERSION"; prints the
#                               wheel's SHA-256

DS_WHEELS=$DS_TEST_ROOT/wheels
mkdir -p "$DS_WHEELS"
export PIP_NO_INDEX=1 PIP_FIND_LINKS=$DS_WHEELS PIP_DISABLE_PIP_VERSION_CHECK=1
export NIX_STORE_DIR=$DS_TEST_ROOT/no-store

ds_make_wheel() {
  (($# == 2)) || ds_fail "ds_make_wheel: usage: ds_make_wheel NAME VERSION"
  python3 - "$1" "$2" "$DS_WHEELS" <<'EOF'
import base64, hashlib, sys, zipfile
name, version, out = sys.argv[1:4]
module = name.replace("-", "_")
info = f"{module}-{version}.dist-info"
files = {
    f"{module}/__init__.py": f'def main():\n    print("{name} {version}")\n',
    f"{info}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n",
    f"{info}/WHEEL": "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    f"{info}/entry_points.txt": f"[console_scripts]\n{name} = {module}:main\n",
}
record = []
for path, text in files.items():
    data = text.encode()
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    record.append(f"{path},sha256={digest},{len(data)}")
record.append(f"{info}/RECORD,,")
wheel = f"{out}/{module}-{version}-py3-none-any.whl"
with zipfile.ZipFile(wheel, "w") as archive:
    for path, text in files.items():
        archive.writestr(path, text)
    archive.writestr(f"{info}/RECORD", "\n".join(record) + "\n")
with open(wheel, "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
EOF
}
