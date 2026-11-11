# The checks that also run on a Mac (checks.aarch64-darwin, built by the checks job of
# .github/workflows/macos-smoke.yml on release tags and nightly): their tests are platform
# independent and mean something on darwin, and their definitions build nothing for Linux. The
# others stay Linux-only: they build x86_64-linux generations, need Linux tools (APT, dpkg, the
# bash 3.2 build of the stage-0 tests) or test the Linux platform layer. nix/outputs.nix exports
# them for aarch64-darwin, and checks.darwin-platform runs their test suites on Linux with the
# platform forced to darwin.
[
  "darwin-eval" # the darwin platform layer and the darwin instance contract, natively
  "harness" # the stubs and helpers that every test check runs on
  "privacy" # the scanner behind the pre-push hook and contribute check
  "python-core" # the Python package and its primitives, the instance lock among them
  "settings" # the settings engine in a darwin home
  "settings-jsonc" # the JSONC reader of the settings engine
  "skeleton" # the dispatcher and the packaged CLI with its darwin toolchain
  "cli-incoming" # what other machines changed: the questions, on clones of a bare remote
  "skills-tracking" # the agent hooks with a fake agent, the debounce and the capture
]
