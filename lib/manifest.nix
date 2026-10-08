# Mirror rendering: the files an instance commits under
# .dotsteward/ for consumers that run before anything is built, and their
# staleness check.
#
#   mirrors { cfg, root, framework, pins, manifests }
#       -> { "manifest.<system>.json" = text; "stage0.<platform>.env" = text; }
#     manifests maps every system of nix.systems to its evaluated manifest
#     (Home Manager dotsteward.manifest of the check identity).
#   mirrorText { manifest, root, framework }   the manifest mirror
#   stage0Text { cfg, root, pins, system, manifest }
#   staleMirrors { root, mirrors }             problems, [ ] when current
#   pretty VALUE                               JSON, sorted keys, two-space
#                                              indent, final newline
#
# root and framework are the instance root and the framework source as
# strings (store paths in a flake).
#
# .dotsteward/manifest.<system>.json is the manifest as pretty JSON (byte
# identical to `jq -S --indent 2 .`) with every value that changes without a
# change of the instance contract taken out: framework.rev and
# framework.narHash are dropped (framework.version stays), and store paths
# become stable names: <instance>/<path> inside the instance root,
# <dotsteward>/<path> inside the framework source, <store>/<name> for any
# other store path (a copied hook script, for example). Without that, every
# commit of the instance or of the framework would make the mirror stale.
#
# .dotsteward/stage0.<platform>.env is sourced by the pre-Nix stage-0
# bootstrap, so it is plain bash 3.2: NAME=value and NAME=(values) lines
# only, every value shell-quoted (single quotes where needed, so nothing
# expands at source time: "~" and "${XDG_STATE_HOME:-...}" stay literal for
# stage-0 to expand). Variables, all prefixed DS_STAGE0_:
#   SCHEMA_VERSION (1), SYSTEM, PLATFORM
#   INSTANCE_REMOTE           [instance] remote
#   STATE_ROOT                [state] root, unexpanded
#   LEGACY_ENV                [compat] legacy_env (true or false)
#   HOST_INPUT                [compat] host_input
#   VERSIONS_LOCK             [pins] versions_lock (instance-relative)
#   PROFILES                  array of profile names
#   PROFILE_MODES             array of <profile>=<mode>
#   DEFAULT_PROFILE, CHECK_PROFILE, BOOTSTRAP_PROFILE
#   FAST_PATH_OS_ID, FAST_PATH_OS_VERSION, FAST_PATH_ARCHITECTURE,
#   FAST_PATH_DESKTOP_CONTAINS (empty when unset), FAST_PATH_DETECTORS
#                             (array)                         Linux
#   FAST_PATH_MIN_VERSION, FAST_PATH_ARCHITECTURE            darwin
#   DETECTORS                 array of preflight detector names (sorted);
#   DETECTOR_<i>_ARGV         array, DETECTOR_<i>_MATCH_LINE, per index i
#   BACKUP_PATHS              array: core and component backup paths, then
#                             every settings target path with at least one
#                             buffer entry and backup = true (a buffer
#                             [targets.<name>] replaces a component target
#                             of that name) and every file entry path
#   SNAPSHOTS                 array of snapshot names;
#   SNAPSHOT_<i>_ARGV         array, SNAPSHOT_<i>_REQUIRE_COMMAND (empty
#                             when none), per index i
#   PREREQUISITES_APT         array of apt packages installed before Nix
#   NIX_VERSION_AT, NIX_INSTALLER_URL_AT, NIX_INSTALLER_SIZE_AT,
#   NIX_INSTALLER_SHA256_AT   lock paths of the Nix pin
#   NIX_VERSION, NIX_INSTALLER_URL, NIX_INSTALLER_SIZE,
#   NIX_INSTALLER_SHA256      their values (stage-0 runs without jq)
{ lib, dsLib, ... }:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    isAttrs
    isList
    isString
    toJSON
    ;
  inherit (lib) escapeShellArg;

  # --- Pretty JSON ------------------------------------------------------------

  render =
    indent: value:
    let
      inner = indent + "  ";
    in
    if isAttrs value then
      if value == { } then
        "{}"
      else
        "{\n"
        + concatStringsSep ",\n" (
          map (key: "${inner}${toJSON key}: ${render inner value.${key}}") (attrNames value)
        )
        + "\n${indent}}"
    else if isList value then
      if value == [ ] then
        "[]"
      else
        "[\n" + concatStringsSep ",\n" (map (item: "${inner}${render inner item}") value) + "\n${indent}]"
    else
      toJSON value;

  pretty = value: builtins.unsafeDiscardStringContext (render "" value + "\n");

  # --- Mirror ---------------------------------------------------------------

  storePathPattern = "(${lib.escapeRegex builtins.storeDir}/[0-9a-z]{32}-)";

  stableString =
    { root, framework }:
    string:
    let
      named = builtins.replaceStrings [ "${root}/" "${framework}/" ] [ "<instance>/" "<dotsteward>/" ] (
        if string == root then
          "<instance>"
        else if string == framework then
          "<dotsteward>"
        else
          string
      );
    in
    lib.concatMapStrings (part: if isList part then "<store>/" else part) (
      builtins.split storePathPattern (builtins.unsafeDiscardStringContext named)
    );

  stable =
    prefixes: value:
    if isString value then
      stableString prefixes value
    else if isList value then
      map (stable prefixes) value
    else if isAttrs value then
      lib.mapAttrs (_: stable prefixes) value
    else
      value;

  mirrorText =
    {
      manifest,
      root,
      framework,
    }:
    pretty (
      stable { inherit root framework; } (
        manifest
        // {
          framework = removeAttrs manifest.framework [
            "rev"
            "narHash"
          ];
        }
      )
    );

  # --- Stage-0 --------------------------------------------------------------

  scalar = name: value: "DS_STAGE0_${name}=${escapeShellArg value}";
  array = name: values: "DS_STAGE0_${name}=(${lib.concatMapStringsSep " " escapeShellArg values})";

  union = lib.foldl' (acc: item: if lib.elem item acc then acc else acc ++ [ item ]) [ ];

  # Paths of the settings buffer that stage-0 backs up.
  bufferBackupPaths =
    {
      cfg,
      root,
      system,
      settingsTargets,
    }:
    let
      label = "${cfg.settings.buffer_dir}/buffer.toml";
      file = root + "/${label}";
      buffer = if builtins.pathExists file then builtins.fromTOML (builtins.readFile file) else { };
      bufferTargets = buffer.targets or { };
      target =
        entry:
        let
          name = entry.target or (throw "dotsteward: ${label}: entry ${entry.id or "?"} has no target");
        in
        if bufferTargets ? ${name} then
          {
            path = dsLib.platform.selectPath system bufferTargets.${name}.path;
            backup = bufferTargets.${name}.backup or true;
          }
        else if settingsTargets ? ${name} then
          { inherit (settingsTargets.${name}) path backup; }
        else
          throw "dotsteward: ${label}: entry ${entry.id or "?"} names unknown target ${name}";
    in
    lib.concatMap (
      entry:
      if (entry.kind or "key") == "file" then
        [ entry.path ]
      else
        let
          resolved = target entry;
        in
        lib.optional resolved.backup resolved.path
    ) (buffer.entries or [ ]);

  stage0Text =
    {
      cfg,
      root,
      pins,
      system,
      manifest,
    }:
    let
      platform = dsLib.platform.platformOf system;
      profiles = cfg.profiles.names;
      fastPath = cfg.platform.${platform}.fast_path;
      detectorNames = attrNames manifest.preflight_detectors;
      pin = path: toString (dsLib.pinAt pins path "core");
      nixPins = [
        "VERSION"
        "INSTALLER_URL"
        "INSTALLER_SIZE"
        "INSTALLER_SHA256"
      ];
      lockPath = name: "nix.${lib.toLower name}";
      backupPaths = union (
        manifest.backup_paths
        ++ bufferBackupPaths {
          inherit cfg root system;
          settingsTargets = manifest.settings_targets;
        }
      );
      fastPathLines =
        if platform == "linux" then
          [
            (scalar "FAST_PATH_OS_ID" fastPath.os_id)
            (scalar "FAST_PATH_OS_VERSION" fastPath.os_version)
            (scalar "FAST_PATH_ARCHITECTURE" fastPath.architecture)
            (scalar "FAST_PATH_DESKTOP_CONTAINS" (
              if fastPath.desktop_contains == null then "" else fastPath.desktop_contains
            ))
            (array "FAST_PATH_DETECTORS" fastPath.detectors)
          ]
        else
          [
            (scalar "FAST_PATH_MIN_VERSION" fastPath.min_version)
            (scalar "FAST_PATH_ARCHITECTURE" fastPath.architecture)
          ];
      lines = [
        "# Generated by dotsteward from workstation.toml, the components and the lock"
        "# (${system}). Do not edit: `dotsteward sync` regenerates it, and the check"
        "# dotsteward-manifest fails while it is stale. Sourced by stage-0 (bash 3.2)."
        (scalar "SCHEMA_VERSION" "1")
        (scalar "SYSTEM" system)
        (scalar "PLATFORM" platform)
        (scalar "INSTANCE_REMOTE" cfg.instance.remote)
        (scalar "STATE_ROOT" cfg.state.root)
        (scalar "LEGACY_ENV" (lib.boolToString cfg.compat.legacy_env))
        (scalar "HOST_INPUT" cfg.compat.host_input)
        (scalar "VERSIONS_LOCK" cfg.pins.versions_lock)
        (array "PROFILES" profiles)
        (array "PROFILE_MODES" (map (name: "${name}=${cfg.profiles.${name}.mode}") profiles))
        (scalar "DEFAULT_PROFILE" cfg.profiles.default)
        (scalar "CHECK_PROFILE" cfg.profiles.check)
        (scalar "BOOTSTRAP_PROFILE" cfg.profiles.bootstrap)
      ]
      ++ fastPathLines
      ++ [ (array "DETECTORS" detectorNames) ]
      ++ lib.concatLists (
        lib.imap0 (
          index: name:
          let
            detector = manifest.preflight_detectors.${name};
          in
          [
            (array "DETECTOR_${toString index}_ARGV" detector.argv)
            (scalar "DETECTOR_${toString index}_MATCH_LINE" detector.match_line)
          ]
        ) detectorNames
      )
      ++ [
        (array "BACKUP_PATHS" backupPaths)
        (array "SNAPSHOTS" (map (snapshot: snapshot.name) manifest.snapshots))
      ]
      ++ lib.concatLists (
        lib.imap0 (index: snapshot: [
          (array "SNAPSHOT_${toString index}_ARGV" snapshot.argv)
          (scalar "SNAPSHOT_${toString index}_REQUIRE_COMMAND" (
            if snapshot.require_command == null then "" else snapshot.require_command
          ))
        ]) manifest.snapshots
      )
      ++ [ (array "PREREQUISITES_APT" manifest.prerequisites.apt) ]
      ++ map (name: scalar "NIX_${name}_AT" (lockPath name)) nixPins
      ++ map (name: scalar "NIX_${name}" (pin (lockPath name))) nixPins;
    in
    builtins.unsafeDiscardStringContext (lib.concatMapStrings (line: line + "\n") lines);

  # --- Mirrors and staleness ------------------------------------------------

  mirrors =
    {
      cfg,
      root,
      framework,
      pins,
      manifests,
    }:
    lib.listToAttrs (
      lib.concatMap (system: [
        {
          name = "manifest.${system}.json";
          value = mirrorText {
            inherit root framework;
            manifest = manifests.${system};
          };
        }
        {
          name = "stage0.${dsLib.platform.platformOf system}.env";
          value = stage0Text {
            inherit
              cfg
              root
              pins
              system
              ;
            manifest = manifests.${system};
          };
        }
      ]) cfg.nix.systems
    );

  # Every mirror is rendered first, also a missing one, so an evaluation
  # problem of any system (a darwin assertion, say) fails the check of every
  # system.
  staleMirrors =
    { root, mirrors }:
    lib.concatMap (
      name:
      let
        file = root + "/.dotsteward/${name}";
        rendered = mirrors.${name};
      in
      if !builtins.pathExists file then
        builtins.seq rendered [ "dotsteward: .dotsteward/${name} is missing (run `dotsteward sync`)" ]
      else if builtins.readFile file != rendered then
        [ "dotsteward: .dotsteward/${name} is stale (run `dotsteward sync`)" ]
      else
        [ ]
    ) (attrNames mirrors);
in
{
  inherit
    pretty
    mirrorText
    stage0Text
    bufferBackupPaths
    mirrors
    staleMirrors
    ;
}
