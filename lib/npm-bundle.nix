# mkNpmBundle: npm dependencies installed as one package, with wrappers for
# the commands an instance wants on PATH.
#
#   mkNpmBundle {
#     pkgs, pname, version,
#     src,                # directory with package.json and package-lock.json
#     commands,           # bins of node_modules/.bin to wrap, in order
#     npmDepsHash ? null, # hash of the fetchNpmDeps cache, or
#     npmDeps ? null,     # a prebuilt npm cache; set exactly one of the two
#     nodejs ? pkgs.nodejs,
#     extraPath ? { },    # command -> [ package or absolute directory ]
#     meta ? { },
#   }
#
# A src given as a path, or as a string naming a directory inside a store
# path (root + "/packages/x" in an instance), is copied into a store path of
# its own named after its last component, exactly like a path literal in a
# flake: the bundle then depends on that directory only, not on the whole
# instance source. A derivation src is used as is.
#
# The result is pkgs.buildNpmPackage with dontNpmBuild = true. Its install
# phase copies node_modules, package.json and package-lock.json to
# $out/lib/<pname> and wraps each command as $out/bin/<command> with PATH
# prefixed by <nodejs>/bin, then the command's extraPath entries (a package
# contributes its bin directory). The command list is written greedily on
# lines of at most 80 characters. The derivation carries exactly the
# attributes of a hand-written buildNpmPackage recipe with the same install
# phase (pname, version, src, nodejs, npmDepsHash or npmDeps, dontNpmBuild,
# nativeBuildInputs = [ makeWrapper ], installPhase), so moving such a recipe
# here keeps its store path.
{ lib, ... }:
{
  pkgs,
  pname,
  version,
  src,
  commands,
  npmDepsHash ? null,
  npmDeps ? null,
  nodejs ? pkgs.nodejs,
  extraPath ? { },
  meta ? { },
}:
let
  inherit (builtins)
    isString
    match
    stringLength
    toJSON
    ;

  fail = message: throw "dotsteward: mkNpmBundle ${pname}: ${message}";

  validName = name: isString name && match "[A-Za-z0-9_][A-Za-z0-9._+@-]*" name != null;

  firstInvalid = lib.findFirst (name: !validName name) null commands;
  firstDuplicate = lib.findFirst (name: lib.count (other: other == name) commands > 1) null commands;
  firstUnknown = lib.findFirst (name: !lib.elem name commands) null (lib.attrNames extraPath);

  # A PATH entry: a package's bin directory, or an absolute directory without
  # characters that are special inside double quotes.
  pathEntry =
    command: entry:
    if lib.isDerivation entry then
      "${lib.getBin entry}/bin"
    else if isString entry && match "/[^\"$`\\\\]*" entry != null then
      entry
    else
      fail "extraPath of ${command}: ${toJSON entry} is neither a package nor a plain absolute directory";

  extraDirs = lib.mapAttrs (command: entries: map (pathEntry command) entries) extraPath;

  # Greedy packing of the command names on lines of at most 80 characters.
  lines = lib.foldl' (
    acc: name:
    if acc == [ ] then
      [ name ]
    else
      let
        last = lib.last acc;
      in
      if stringLength last + 1 + stringLength name <= 80 then
        lib.init acc ++ [ "${last} ${name}" ]
      else
        acc ++ [ name ]
  ) [ ] commands;

  installPhase = lib.concatStrings (
    [
      "runHook preInstall\n"
      "install_root=\"$out/lib/${pname}\"\n"
      "mkdir -p \"$install_root\" \"$out/bin\"\n"
      "cp -R node_modules package.json package-lock.json \"$install_root/\"\n"
      "for command_name in \\\n"
      "  ${lib.concatStringsSep " \\\n  " lines}; do\n"
      "  runtime_path=\"${nodejs}/bin\"\n"
    ]
    ++ lib.concatMap (command: [
      "  if [[ \"$command_name\" == ${command} ]]; then\n"
      "    runtime_path=\"$runtime_path:${lib.concatStringsSep ":" extraDirs.${command}}\"\n"
      "  fi\n"
    ]) (lib.filter (command: extraDirs ? ${command}) commands)
    ++ [
      "  makeWrapper \"$install_root/node_modules/.bin/$command_name\" \"$out/bin/$command_name\" \\\n"
      "    --prefix PATH : \"$runtime_path\"\n"
      "done\n"
      "runHook postInstall\n"
    ]
  );

  source =
    if builtins.isPath src || (isString src && !lib.isDerivation src) then
      builtins.path {
        path = src;
        # Only the name: the context of a store subpath string stays on path.
        name = builtins.unsafeDiscardStringContext (baseNameOf (toString src));
      }
    else
      src;

  args = {
    inherit
      pname
      version
      nodejs
      installPhase
      ;
    src = source;
    dontNpmBuild = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
  }
  // (if npmDeps != null then { inherit npmDeps; } else { inherit npmDepsHash; })
  // lib.optionalAttrs (meta != { }) { inherit meta; };
in
if !validName pname then
  throw "dotsteward: mkNpmBundle: invalid pname ${toJSON pname}"
else if (npmDepsHash == null) == (npmDeps == null) then
  fail "set exactly one of npmDepsHash and npmDeps"
else if commands == [ ] then
  fail "commands must not be empty"
else if firstInvalid != null then
  fail "invalid command name ${toJSON firstInvalid}"
else if firstDuplicate != null then
  fail "duplicate command ${firstDuplicate}"
else if firstUnknown != null then
  fail "extraPath names ${firstUnknown}, which is not a command"
else
  lib.deepSeq extraDirs (pkgs.buildNpmPackage args)
