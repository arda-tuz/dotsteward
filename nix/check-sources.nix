# The framework files of every check, in one place: the source set of each
# nix/checks/<name>.nix. A check's build copies its set (mkTestCheck of
# nix/packages/dotsteward.nix) or reads its inputs from it, and depends on
# no other file of the tree, so a change outside the set of a check never
# rebuilds it: a fix of a README rebuilds only the checks that read that
# README, a fix of one suite only the checks of that suite.
# tests/host/test-check-sources.sh holds every check to its set, and
# checks.check-sources holds the tree to the coverage below.
#
# A set that misses an input turns a change of that input into a stale,
# cached result, so the sets name whole directories wherever they can, and a
# check whose tests start to read another directory fails until its set
# holds it.
#
# - The files a release changes (VERSION, template/flake.nix, the plugin
#   manifests and the Claude marketplace entry, the version contract of
#   tests/static/test-version-contract.sh) are only in the sets of the
#   checks that read them: the checks of the version wiring and the checks
#   whose derivation carries the version anyway (they use the packaged CLI,
#   whose files are `package`, or build instance outputs). mkTestCheck gives
#   every other check the placeholder VERSION 0.0.0, so a release rebuilds
#   none of them.
# - `framework` is the framework as an instance sees it: the tree without
#   its tests, documentation, flake plumbing (nix/), repository metadata,
#   agent-plugin channel and release files.
# - The whole-tree checks copy every file of the tree: privacy, skeleton and
#   static scan it, contribute-round searches it for the version (no file
#   but VERSION and its copies carries it), and the checks that build
#   instance outputs inside this flake depend on it as an instance depends
#   on its framework input (the generations link the framework skills from
#   the framework source, and the components name their hooks and probes in
#   place there), so a change to any file of the tree rebuilds them. For the
#   coverage they count with the files their own tests read.
# - Every file of the tree is in the set of a check, in `untested` (no
#   check reads it) or in `evaluated` (only the evaluation of the flake
#   reads it), so a new file or directory cannot escape every check unseen.
{ lib }:
let
  fs = lib.fileset;
  root = ../.;

  # Every file of the tree: the files of the flake source, without .git when
  # the flake is evaluated as a path.
  tree = fs.difference root (fs.maybeMissing (root + "/.git"));

  # paths PATH...: the files of the PATHs (files or directories) of the tree.
  paths = list: fs.unions (map (path: root + "/${path}") list);

  # --- shared parts ---------------------------------------------------------------

  # The test runner, the harness with its stubs, and the fixtures the
  # harness reads itself.
  runner = paths [
    "tests/run.sh"
    "tests/lib"
    "tests/fixtures/common"
  ];

  # The CLI run from the tree: dispatcher, commands, libraries, the Python
  # package and the schemas it validates with.
  cli = paths [
    "cli"
    "schema"
  ];

  # The catalog as the CLI reads it: one directory per component (the
  # component seeds, which every catalog component has).
  catalog = fs.fileFilter (file: file.name == "seed.json") (root + "/modules/components");

  # The files of the packaged CLI (nix/packages/dotsteward.nix), for the
  # checks that run it.
  package = import ./packages/dotsteward-files.nix { inherit lib; };

  # The files of the packaged CLI but the release files: the source of the
  # CLI package that the Nix suites evaluate (and hash) inside the sandbox
  # without testing the version wiring.
  packageFiles = fs.difference package release;

  # The Nix library and modules the tests evaluate with nix-instantiate,
  # with the CLI package it imports lazily and the framework skills the
  # skills module looks for.
  nixLibrary = paths [
    "lib"
    "modules"
    "nix/packages"
    "schema"
    "skills"
  ];

  # The shared helpers, preludes and fixtures of the Nix suites.
  nixSupport = paths [
    "tests/nix/core/helpers.sh"
    "tests/nix/core/prelude.nix"
    "tests/nix/core/fixtures"
    "tests/nix/instance/helpers.sh"
    "tests/nix/instance/prelude.nix"
    "tests/nix/instance/flake-instances.nix"
    "tests/nix/instance/fixtures"
    "tests/nix/lib/helpers.sh"
    "tests/nix/lib/prelude.nix"
    "tests/nix/lib/fixtures"
    "tests/fixtures/instances"
  ];

  # Framework mode of `dotsteward static` (the seeds check and the seed
  # lock paths of the component suites).
  staticFramework = paths [
    "privacy"
    "tests/static/allowed-commands.txt"
    "tests/static/seed-lock-paths.nix"
  ];

  release = paths [
    "VERSION"
    "template/flake.nix"
    "plugins/dotsteward/.claude-plugin/plugin.json"
    "plugins/dotsteward/.codex-plugin/plugin.json"
    ".claude-plugin/marketplace.json"
  ];

  # Markdown documentation: every Markdown file but the skills' and the
  # template's, which are content an instance receives.
  markdown =
    fs.difference (fs.intersection tree (fs.fileFilter (file: file.hasExt "md") root))
      (paths [
        "skills"
        "template"
      ]);

  framework = fs.difference tree (
    fs.unions [
      (paths [
        "tests"
        "docs"
        "nix"
        ".github"
        ".githooks"
        ".editorconfig"
        ".gitignore"
        "pyproject.toml"
        "plugins"
        ".claude-plugin"
        ".agents"
      ])
      markdown
      release
    ]
  );

  # The base of the catalog component suites: the framework, the library
  # they evaluate, the shared Nix test support and static's framework mode.
  componentBase = fs.unions [
    runner
    framework
    nixLibrary
    nixSupport
    staticFramework
  ];

  # --- the checks ---------------------------------------------------------------

  # name -> the files the check's tests read. A whole-tree check copies the
  # whole tree instead and counts with these files for the coverage.
  checks = {
    agents = fs.unions [
      runner
      cli
      (paths [
        "tools"
        "tests/agents"
      ])
    ];
    check-sources = fs.unions [ ];
    cli-bootstrap = fs.unions [
      runner
      cli
      (fs.difference (paths [ "template" ]) release)
      (paths [
        "tools"
        "tests/cli/bootstrap"
      ])
    ];
    cli-context = fs.unions [
      runner
      package
      (paths [
        "tests/cli/context"
        "tests/nix/lib/helpers.sh"
        "tests/nix/lib/fixtures/valid/minimal.toml"
        # test-parallelism.sh: the documents that name the smallest memory
        "README.md"
        "docs/workstation-toml.md"
        "plugins/dotsteward/skills/dotsteward-init/references/platform-prereqs.md"
      ])
    ];
    cli-e2e = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines"
        "tools"
        "modules/core/github-release-deb-e2e.sh"
        "tests/cli/e2e"
        "tests/agents/helpers.sh"
      ])
    ];
    cli-gate = fs.unions [
      runner
      cli
      (paths [ "tests/cli/gate" ])
    ];
    cli-host = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines"
        "privacy"
        "tools"
        "tests/cli/host"
        "tests/cli/e2e/helpers.sh"
        "tests/agents/helpers.sh"
      ])
    ];
    cli-incoming = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines"
        "privacy"
        "template/.dotsteward"
        "template/bootstrap.sh"
        "tools"
        "tests/agents/helpers.sh"
        "tests/static/helpers.sh"
        "tests/skills-tracking/capture-helpers.sh"
        "tests/skills-tracking/fixtures"
        "tests/incoming"
      ])
    ];
    cli-launcher = fs.unions [
      runner
      (paths [
        "template/.dotsteward"
        "tests/cli/launcher"
      ])
    ];
    cli-lib = fs.unions [
      runner
      package
      catalog
      (paths [
        "lib"
        "tests/cli/lib"
        "tests/cli/config"
        # test-hook-contract.sh: the frozen interface and a real hook
        "docs/hook-library.md"
        "tests/cli/methods/helpers.sh"
        "tests/nix/lib/helpers.sh"
        "tests/nix/lib/prelude.nix"
        "tests/nix/lib/fixtures"
      ])
    ];
    cli-methods = fs.unions [
      runner
      cli
      (paths [ "tests/cli/methods" ])
    ];
    cli-rebuild = fs.unions [
      runner
      cli
      (paths [ "tests/cli/rebuild" ])
    ];
    cli-update = fs.unions [
      runner
      cli
      catalog
      (paths [ "tests/cli/update" ])
    ];
    cli-upgrade = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines"
        "privacy"
        "tests/cli/update/helpers.sh"
        "tests/engines/pins/apply"
        "tests/engines/pins/check"
        "tests/upgrade"
      ])
    ];
    component-claude-code = fs.unions [
      componentBase
      (paths [
        "modules/components/claude-code"
        "tests/static"
        "tests/cli/methods/helpers.sh"
        "tests/nix/components/claude-code"
      ])
    ];
    component-codex = fs.unions [
      componentBase
      (paths [
        "modules/components/codex"
        "tests/nix/components/codex"
      ])
    ];
    component-github-release-deb = fs.unions [
      componentBase
      (paths [
        "modules/components/craft-anything"
        "modules/components/deckcraft"
        "modules/components/gridcraft"
        "modules/components/pdfcraft"
        "modules/components/wordcraft"
        "tests/nix/components/github-release-deb"
      ])
    ];
    component-herdr = fs.unions [
      componentBase
      package
      (paths [
        "modules/components/herdr"
        "tests/engines/settings/core/helpers.sh"
        "tests/engines/settings/core/test-reload.sh"
        "tests/nix/components/herdr"
      ])
    ];
    component-opencode-pi = fs.unions [
      componentBase
      (paths [
        "modules/components/opencode-pi"
        "tests/nix/components/opencode-pi"
      ])
    ];
    component-shell = fs.unions [
      componentBase
      package
      (paths [
        "modules/components/shell"
        "tests/nix/components/shell"
      ])
    ];
    component-vscode = fs.unions [
      componentBase
      package
      (paths [
        "modules/components/vscode"
        "tests/cli/methods/helpers.sh"
        "tests/engines/settings/core/helpers.sh"
        "tests/nix/components/vscode"
      ])
    ];
    contribute = fs.unions [
      runner
      cli
      catalog
      (paths [
        "privacy"
        # the commit hooks: test-commit.sh runs them, postCheck lints them
        ".githooks/commit-msg"
        ".githooks/pre-commit"
        "tests/contribute/local"
      ])
    ];
    contribute-remote = fs.unions [
      runner
      cli
      (paths [
        "privacy"
        "modules"
        "template/.dotsteward"
        # the release workflow's command (test-release-workflow.sh)
        "tools/version.sh"
        "tests/contribute/local"
        "tests/contribute/remote"
      ])
    ];
    contribute-round = fs.unions [
      runner
      package
      release
      (paths [
        "modules"
        # test-version-tool.sh: the tool and every copy of VERSION
        "tools/version.sh"
        ".agents/plugins/marketplace.json"
        # test-ci-split.sh: the workflows contribute waits for and the
        # release workflow
        ".github/workflows/ci.yml"
        ".github/workflows/privacy.yml"
        ".github/workflows/release.yml"
        "tests/fixtures"
        "tests/contribute/local"
        "tests/contribute/remote"
        "tests/contribute/round"
        "tests/skeleton/helpers.sh"
      ])
    ];
    darwin-eval = fs.unions [
      runner
      framework
      package
      (paths [
        "tests/cli/darwin"
        "tests/fixtures/instances/full-darwin"
      ])
    ];
    harness = fs.unions [
      runner
      (paths [ "tests/harness" ])
    ];
    init = fs.unions [
      runner
      framework
      package
      nixLibrary
      nixSupport
      (paths [
        "tests/instance/init"
        "tests/instance/template/helpers.sh"
      ])
    ];
    manifest-consistent = fs.unions [
      runner
      framework
      package
      nixLibrary
      nixSupport
      (paths [ "tests/nix/instance/consistency" ])
    ];
    nix-assertions = fs.unions [
      runner
      nixLibrary
      nixSupport
      (paths [ "tests/nix/instance/assertions" ])
    ];
    nix-core = fs.unions [
      runner
      nixLibrary
      nixSupport
      packageFiles
      (paths [
        "flake.lock"
        "tests/nix/core"
        "tests/fixtures/npm-bundle"
      ])
    ];
    nix-instance = fs.unions [
      runner
      framework
      package
      nixLibrary
      nixSupport
      (fs.difference (paths [ "tests/nix/instance" ]) (paths [
        "tests/nix/instance/assertions"
        "tests/nix/instance/consistency"
      ]))
    ];
    nix-lib = fs.unions [
      runner
      nixLibrary
      (paths [
        "flake.lock"
        "tests/nix/lib"
      ])
    ];
    npm-bundle = paths [ "tests/fixtures/npm-bundle" ];
    pins-check = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines/pins"
        "tests/engines/pins/check"
      ])
    ];
    pins-latest = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines/pins"
        "tests/engines/pins/latest"
      ])
    ];
    pins-apply = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines/pins"
        "privacy"
        "tests/engines/pins/apply"
        "tests/engines/pins/check"
      ])
    ];
    privacy = fs.unions [
      runner
      cli
      (paths [
        "privacy"
        "tests/privacy"
      ])
    ];
    probes = fs.unions [
      runner
      cli
      catalog
      (paths [ "tests/probes" ])
    ];
    python-core = fs.unions [
      runner
      cli
      catalog
      # every Python file of the tree: the check lints them all
      (fs.intersection tree (fs.fileFilter (file: file.hasExt "py") root))
      (paths [
        # test-run-report.sh: the page of the exit codes
        "docs/exit-codes.md"
        "engines"
        "nix/checks"
        "nix/packages/dotsteward.nix"
        "pyproject.toml"
        "tests/cli/core"
      ])
    ];
    settings = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines/local-maintained-files"
        "tests/engines/settings/core"
        "tests/nix/lib/fixtures/valid/minimal.toml"
      ])
    ];
    settings-jsonc = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines/local-maintained-files"
        "tests/engines/settings/core/helpers.sh"
        "tests/engines/settings/core/fixtures"
        "tests/engines/settings/jsonc"
      ])
    ];
    skeleton = fs.unions [
      runner
      cli
      (paths [
        "tests/skeleton"
        "tests/fixtures"
        "flake.nix"
        "flake.lock"
        "VERSION"
        "LICENSE"
        "README.md"
        "CONTRIBUTING.md"
        "SECURITY.md"
        ".gitignore"
        ".editorconfig"
        "nix/outputs.nix"
        "nix/packages/dotsteward.nix"
        "nix/checks/skeleton.nix"
        "lib/default.nix"
      ])
    ];
    skills-tracking = fs.unions [
      runner
      cli
      catalog
      (paths [
        "engines"
        "privacy"
        "template/.dotsteward"
        "template/bootstrap.sh"
        "modules/components/claude-code/skill-hooks.sh"
        "modules/components/codex/skill-hooks.sh"
        "tools"
        "tests/agents/helpers.sh"
        "tests/static/helpers.sh"
        "tests/skills-tracking"
      ])
    ];
    skills = fs.unions [
      runner
      package
      (fs.fileFilter (file: file.name == "README.md") (root + "/modules/components"))
      (paths [
        "engines"
        "skills"
        "tools"
        "plugins"
        ".claude-plugin"
        ".agents"
        "LICENSE"
        "tests/skills"
        "tests/fixtures/skills-contract"
      ])
    ];
    stage0-generated = paths [
      "tools/gen-stage0.sh"
      "cli/commands/preflight.sh"
      "cli/lib/lib.sh"
      "cli/lib/stage0.sh"
      "template/bootstrap.sh"
    ];
    static = fs.unions [
      runner
      package
      nixLibrary
      nixSupport
      markdown
      release
      (paths [
        "docs"
        "tests/static"
        ".github/workflows/ci.yml"
        # test-darwin-checks.sh: the macOS workflow
        ".github/workflows/macos-smoke.yml"
        ".gitignore"
        "nix/checks/static.nix"
      ])
    ];
    template-full = fs.unions [
      framework
      package
      (paths [ "tests/fixtures/instances/full" ])
    ];
    template-static = fs.unions [
      runner
      framework
      package
      nixLibrary
      nixSupport
      (paths [
        "tests/instance/template"
        "tests/static"
      ])
    ];
  };

  # Checks whose source is every file of the tree: the scans of the whole
  # tree (contribute-round's search for the version among them), and the
  # checks that build instance outputs of this flake.
  wholeTree = [
    "privacy"
    "skeleton"
    "static"
    "contribute-round"
    "component-herdr"
    "component-shell"
    "component-vscode"
    "darwin-eval"
    "nix-instance"
    "template-full"
    "template-static"
  ];

  # Files that no check reads: the suites that run outside the build
  # sandbox (on the host, in GitHub Actions or in virtual machines), the
  # workflows and hooks they cover, and the documentation no test reads.
  untested = paths [
    "tests/host"
    "tests/hooks"
    "tests/apt-worlds"
    "tests/channels"
    "tests/ci"
    "tests/container"
    "tests/vm"
    ".githooks/pre-push"
    ".github/workflows/channels.yml"
    ".github/workflows/clean-install.yml"
  ];

  # Files that only the evaluation of the flake reads: the flake and its
  # plumbing, whose every change shows in the derivations it defines.
  evaluated = paths [
    "flake.nix"
    "nix"
  ];

  sets = lib.mapAttrs (name: set: if lib.elem name wholeTree then tree else set) checks;

  # relative FILESET: the files of FILESET, relative to the root, sorted.
  relative =
    set:
    let
      prefix = toString root + "/";
    in
    lib.sort lib.lessThan (map (file: lib.removePrefix prefix (toString file)) (fs.toList set));

  covered = fs.unions (
    lib.attrValues checks
    ++ [
      untested
      evaluated
    ]
  );
in
{
  inherit root;

  # The source set of each check, as a file set.
  filesets = sets;

  # sources.<name>: the store copy of the source set of check <name>.
  sources = lib.mapAttrs (
    name: set:
    fs.toSource {
      inherit root;
      fileset = set;
    }
  ) sets;

  # hasVersion NAME: whether the set of check NAME holds VERSION.
  hasVersion = name: fs.toList (fs.intersection sets.${name} (root + "/VERSION")) != [ ];

  # The files of the tree in no set and in no list.
  uncovered = relative (fs.difference tree covered);

  # For tests/host/test-check-sources.sh: every list as relative paths.
  report = {
    sources = lib.mapAttrs (name: relative) sets;
    covers = lib.mapAttrs (name: relative) checks;
    untested = relative untested;
    evaluated = relative evaluated;
    inherit wholeTree;
  };
}
