# The package fixpoint of an instance.
#
#   fixpoint { ctx, catalog, instance, base, extraPackages }
#     -> { packages, checks }
#
# ctx is the package context without `packages` ({ pkgs, pins, inputs,
# system, lib, dsLib, root, cfg }); every package.nix and extraPackages get
# it with `packages` = the final package set, so a package can use another
# one (lib.fix). catalog and instance list the enabled components as
# [ { name; dir; } ]; the instance list wins over the catalog list for an
# attribute both declare, and extraPackages win over both (spec formula
# base // catalog // instance // extraPackages). base holds the instance CLI.
#
# Convention of <dir>/package.nix (optional, catalog and instance alike):
# a function of the package context returning an attribute set; each
# attribute is published as packages.<system>.<attribute> and its value is
# either a derivation or { package = <derivation>; check = true; }, which
# also adds checks.<system>.<attribute>. check defaults to false.
#
#   { pkgs, pins, dsLib, ... }:
#   {
#     example-tool = {
#       package = pkgs.callPackage ./example-tool.nix { };
#       check = true;
#     };
#   }
#
# Within one group (catalog or instance) an attribute declared by two
# components is an error; `dotsteward` and `local-maintained-files` are
# reserved for the CLI and the settings alias.
{ lib, ... }:
let
  inherit (builtins)
    attrNames
    isAttrs
    isBool
    isFunction
    pathExists
    ;

  reserved = [
    "dotsteward"
    "local-maintained-files"
  ];

  # The entries { <attr> = { package; check; component; }; } of one
  # component, or { } without a package.nix.
  componentEntries =
    ctx:
    { name, dir }:
    let
      file = dir + "/package.nix";
      label = "components/${name}/package.nix";
      value = import file;
      result =
        if isFunction value then
          value ctx
        else
          throw "dotsteward: ${label} must be a function of the package context";
      checked =
        if !(isAttrs result) then
          throw "dotsteward: ${label} must return an attribute set of packages"
        else
          let
            taken = lib.filter (attr: lib.elem attr reserved) (attrNames result);
          in
          if taken != [ ] then throw "dotsteward: ${label}: ${lib.head taken} is reserved" else result;
      invalid =
        attr: throw "dotsteward: ${label}: ${attr} must be a derivation or { package; check ? false; }";
      entry =
        attr: value:
        let
          record =
            if lib.isDerivation value then
              {
                package = value;
                check = false;
              }
            else if
              isAttrs value && value ? package && lib.subtractLists [ "package" "check" ] (attrNames value) == [ ]
            then
              {
                package = if lib.isDerivation value.package then value.package else invalid attr;
                check =
                  let
                    check = value.check or false;
                  in
                  if isBool check then check else throw "dotsteward: ${label}: ${attr}.check must be a boolean";
              }
            else
              invalid attr;
        in
        {
          component = name;
          inherit (record) package check;
        };
    in
    if pathExists file then lib.mapAttrs entry checked else { };

  # The entries of a group; an attribute declared twice is an error. The
  # components are visited by name, so the message does not depend on
  # [components] order.
  groupEntries =
    ctx: components:
    lib.foldl' (
      acc: component:
      let
        entries = componentEntries ctx component;
        clash = lib.filter (attr: acc ? ${attr}) (attrNames entries);
      in
      if clash != [ ] then
        let
          attr = lib.head clash;
        in
        throw "dotsteward: package ${attr} is declared by components ${acc.${attr}.component} and ${component.name}"
      else
        acc // entries
    ) { } (lib.sort (a: b: a.name < b.name) components);
in
{
  fixpoint =
    {
      ctx,
      catalog,
      instance,
      base,
      extraPackages,
    }:
    let
      fixed = lib.fix (
        self:
        let
          context = ctx // {
            inherit (self) packages;
          };
          entries = groupEntries context catalog // groupEntries context instance;
        in
        {
          inherit entries;
          packages = base // lib.mapAttrs (_: entry: entry.package) entries // extraPackages context;
        }
      );
    in
    {
      inherit (fixed) packages;
      # Package checks use the final package (extraPackages may replace it).
      checks = lib.mapAttrs (attr: _: fixed.packages.${attr}) (
        lib.filterAttrs (_: entry: entry.check) fixed.entries
      );
    };
}
