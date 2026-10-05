# pinAt PINS PATH COMPONENT: the value at the dotted PATH of a parsed
# versions.lock.json (PINS), for example
#   pinAt pins "nix_packages.starship.expected" "shell"
# A missing key, or a non-table where the path continues, throws
#   dotsteward: versions.lock.json lacks <PATH> (required by component <COMPONENT>)
# Only the values along PATH are forced. A present null is returned as is.
{ lib, ... }:
pins: path: component:
let
  segments = lib.splitString "." path;
  required = "(required by component ${component})";
  lacks = throw "dotsteward: versions.lock.json lacks ${path} ${required}";
  walk =
    value: rest:
    if rest == [ ] then
      value
    else if builtins.isAttrs value && value ? ${builtins.head rest} then
      walk value.${builtins.head rest} (builtins.tail rest)
    else
      lacks;
in
if !(builtins.isString path) || builtins.elem "" segments then
  throw "dotsteward: invalid lock path ${builtins.toJSON path} ${required}"
else
  walk pins segments
