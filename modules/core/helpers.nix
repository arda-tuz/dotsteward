# Functions shared by the core modules (not a module).
#
#   enabled CFG COMPONENTS     enabled components in [components] order (then
#                              any other declared name, sorted), as
#                              [ { name; component; } ]
#   isActive PROFILE PLATFORM COMPONENT
#                              enabled, scoped to PROFILE (profiles null or
#                              containing it) and supporting PLATFORM
#   settingsTargets SYSTEM PLATFORM_LIB ENTRIES
#                              { <target> = { component, path, format, ... } }
#                              with paths selected for SYSTEM (dsLib.platform);
#                              a target name declared twice is an error
#   reloadHooks ENTRIES        { <hook> = { component, command, ... } }
#   renderReload SPEC          a reload spec with snake_case keys
#   shellWord WHAT HOME VALUE  VALUE as a double-quoted bash word: a leading
#                              "~" and a "~" starting a ${NAME:-word} default
#                              become HOME; $NAME, ${NAME} and ${NAME:-word}
#                              are kept for the shell; any other shell syntax
#                              is an error naming WHAT
{ lib }:
let
  inherit (builtins)
    attrNames
    concatMap
    elem
    filter
    head
    isList
    isString
    length
    match
    toJSON
    ;

  renderReload = spec: {
    inherit (spec) command timeout env;
    unset_env = spec.unsetEnv;
    require_command = spec.requireCommand;
    on_success = spec.onSuccess;
    on_failure = spec.onFailure;
  };

  # Groups the entries of every component (a list of { name; component; })
  # by key, failing on a key declared by two components.
  uniqueBy =
    what: entries:
    lib.foldl' (
      acc: entry:
      if acc ? ${entry.key} then
        throw "dotsteward: ${what} ${entry.key} is declared by components ${acc.${entry.key}.component} and ${entry.component}"
      else
        acc // { ${entry.key} = entry; }
    ) { } entries;

  # Characters a literal part of a shell word may contain: anything but the
  # characters with a meaning inside double quotes.
  literalOk = text: match "[^$`\"\\\\]*" text != null;

  expandTilde =
    home: text:
    if text == "~" then
      home
    else if lib.hasPrefix "~/" text then
      home + lib.removePrefix "~" text
    else
      text;
in
{
  inherit renderReload;

  enabled =
    cfg: components:
    let
      order = cfg.components.order or [ ];
      declared = attrNames components;
      names =
        filter (name: elem name declared) order
        ++ lib.sort lib.lessThan (filter (name: !elem name order) declared);
    in
    map (name: {
      inherit name;
      component = components.${name};
    }) (filter (name: components.${name}.enable) names);

  isActive =
    profile: platform: component:
    component.enable
    && (component.profiles == null || elem profile component.profiles)
    && elem platform component.platforms;

  settingsTargets =
    system: platformLib: entries:
    lib.mapAttrs (_: entry: removeAttrs entry [ "key" ]) (
      uniqueBy "settings target" (
        concatMap (
          { name, component }:
          lib.mapAttrsToList (key: target: {
            inherit key;
            component = name;
            path = platformLib.selectPath system target.path;
            inherit (target) format backup;
            create_if_missing = target.createIfMissing;
            create_mode = target.createMode;
            reload =
              if target.reload == null || isString target.reload then
                target.reload
              else
                renderReload target.reload;
          }) component.settingsTargets
        ) entries
      )
    );

  reloadHooks =
    entries:
    lib.mapAttrs (_: entry: removeAttrs entry [ "key" ]) (
      uniqueBy "reload hook" (
        concatMap (
          { name, component }:
          lib.mapAttrsToList (
            key: spec:
            {
              inherit key;
              component = name;
            }
            // renderReload spec
          ) component.reloadHooks
        ) entries
      )
    );

  shellWord =
    what: home: value:
    let
      # builtins.split keeps the separators as lists of their groups: group 1
      # is the whole expansion, group 2 the ":-word" part of ${NAME:-word}.
      parts = builtins.split "(\\$\\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?}|\\$[A-Za-z_][A-Za-z0-9_]*)" value;
      unsupported = throw "dotsteward: ${what} ${toJSON value} uses unsupported shell syntax (allowed: ~/ at the start, $NAME, \${NAME} and \${NAME:-default} with a literal default)";
      render =
        index: part:
        if isList part then
          let
            expansion = head part;
            default = lib.elemAt part 1;
          in
          if default == null then
            expansion
          else
            let
              word = lib.removePrefix ":-" default;
              prefix = lib.removeSuffix "${default}}" expansion;
            in
            if literalOk word then "${prefix}:-${expandTilde home word}}" else unsupported
        else if literalOk part then
          if index == 0 then expandTilde home part else part
        else
          unsupported;
    in
    if length parts == 0 then "\"\"" else "\"${lib.concatStrings (lib.imap0 render parts)}\"";
}
