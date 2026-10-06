# The vscode catalog component (SPEC 3.5): VS Code from the vendor's
# official builds, its user settings file as a JSONC settings target, and
# optionally the editor variables.
#
# Methods:
#   deb (Linux default)          the official DEB of package code (amd64),
#                                pinned at desktop_packages.vscode of
#                                versions.lock.json; installed in fresh mode
#                                by the system-install transaction when the
#                                installed version is below the pin, never
#                                downgraded; the package's own update
#                                channel stays as the user answers it
#   app-archive (darwin default) the official arm64 archive (a zip holding
#                                Visual Studio Code.app), pinned at
#                                desktop_packages.vscode-darwin-arm64;
#                                installed in fresh mode into ~/Applications,
#                                the installed version read from the bundle's
#                                Info.plist (CFBundleShortVersionString); the
#                                bundle's code command is put on PATH
#   external (both)              installed by the user; code is expected on
#                                PATH
# Both pins are version-addressed downloads of the official update service;
# `pins latest` reads its update API (README.md, maintenance.md).
#
# options (the [components.vscode] options table of workstation.toml):
#   set_default_editor = true    sets EDITOR = "code", VISUAL = "code" and
#                                GIT_EDITOR = "code --wait" in every profile
#                                where the component is active (default:
#                                false, nothing is set)
# Invalid options fail the evaluation with every problem listed.
{
  config,
  lib,
  profile,
  dotsteward,
  ...
}:
let
  inherit (builtins)
    attrNames
    elem
    filter
    isBool
    toJSON
    ;

  name = "vscode";
  inherit (dotsteward) cfg system;
  dsLib = dotsteward.lib;
  helpers = import ../../core/helpers.nix { inherit lib; };
  component = config.dotsteward.components.${name};

  platform = dsLib.platform.platformOf system;

  # The official update service: builds are addressed by version and build
  # name (<updates>/<version>/<build>/stable redirects to the file), and its
  # update API describes the newest stable build (<updates>/api/update/
  # <build>/stable/latest: productVersion, url, sha256hash).
  updates = "https://update.code.visualstudio.com";

  # The pinned method of each platform: its lock path and build name.
  releases = {
    linux = {
      method = "deb";
      pin = "desktop_packages.vscode";
      build = "linux-deb-x64";
    };
    darwin = {
      method = "app-archive";
      pin = "desktop_packages.vscode-darwin-arm64";
      build = "darwin-arm64";
    };
  };

  appName = "Visual Studio Code.app";

  # The platforms of nix.systems whose method is the pinned one: each reads
  # its own pin, and every system's manifest declares the pins declarations
  # of all of them (one lock serves every system).
  methodOn =
    platformName:
    if platformName == platform then
      component.method
    else
      let
        configured =
          if cfg.components ? ${name} then dsLib.config.methodFor cfg name platformName else null;
      in
      if configured == null then releases.${platformName}.method else configured;
  pinnedPlatforms = filter (platformName: methodOn platformName == releases.${platformName}.method) (
    lib.unique (map dsLib.platform.platformOf cfg.nix.systems)
  );

  # --- options ------------------------------------------------------------------

  componentOptions = component.options;
  knownOptions = [ "set_default_editor" ];
  setDefaultEditor = componentOptions.set_default_editor or false;

  optionProblems =
    map (key: "unknown option ${key} (known: ${lib.concatStringsSep ", " knownOptions})") (
      filter (key: !elem key knownOptions) (attrNames componentOptions)
    )
    ++ lib.optional (
      !isBool setDefaultEditor
    ) "options.set_default_editor must be true or false, got ${toJSON setDefaultEditor}";

  active = helpers.isActive profile platform component;

  # The bundle's command directory, as a shell word for home.sessionPath.
  bundleBin =
    let
      dest = component.install.app-archive.dest;
    in
    "$HOME${lib.removePrefix "~" dest}/${component.install.app-archive.appName}/Contents/Resources/app/bin";
in
{
  dotsteward.components.${name} = {
    method = lib.mkDefault releases.${platform}.method;
    supportedMethods = {
      linux = [
        "deb"
        "external"
      ];
      darwin = [
        "app-archive"
        "external"
      ];
    };

    install = {
      deb = {
        inherit (releases.linux) pin;
        packageNames = [ "code" ];
        architecture = "amd64";
      };
      app-archive = {
        inherit (releases.darwin) pin;
        inherit appName;
      };
      external = {
        command = "code";
        versionArgv = [ "--version" ];
      };
    };

    pins = {
      rules = map (
        platformName:
        let
          release = releases.${platformName};
        in
        {
          kind = "download-pin";
          name = release.method;
          at = release.pin;
          version_field = "minimum_version";
          url_contains = "${updates}/{.minimum_version}/${release.build}/stable";
        }
      ) pinnedPlatforms;
      latest = map (
        platformName:
        let
          release = releases.${platformName};
        in
        {
          id = release.pin;
          adapter = "official-manifest";
          at = release.pin;
          current_field = "minimum_version";
          manifest_url = "${updates}/api/update/${release.build}/stable/latest";
          version_field = "productVersion";
          sha256_field = "sha256hash";
          size_url_field = "url";
          url_template = "${updates}/{version}/${release.build}/stable";
          source = "https://code.visualstudio.com/updates";
        }
      ) pinnedPlatforms;
    };

    # The user settings file. The application watches it, so no reload; a
    # file with comments or trailing commas is refused by the settings engine
    # (JSONC), never rewritten.
    settingsTargets.vscode-settings = {
      path = {
        linux = "~/.config/Code/User/settings.json";
        darwin = "~/Library/Application Support/Code/User/settings.json";
      };
      format = "jsonc";
      createIfMissing = true;
    };

    docs = ./README.md;
  };

  home.sessionVariables = lib.mkIf (active && setDefaultEditor == true) {
    EDITOR = "code";
    VISUAL = "code";
    GIT_EDITOR = "code --wait";
  };

  home.sessionPath = lib.mkIf (active && platform == "darwin" && component.method == "app-archive") [
    bundleBin
  ];

  assertions = lib.optionals component.enable (
    map (message: {
      assertion = false;
      message = "dotsteward: component ${name}: ${message}";
    }) optionProblems
  );
}
