# workstation.toml: loading, validation and defaults (schema version 1).
#
# The schema file schema/workstation.schema.json is the single source of the
# accepted keys, their types and their static defaults: this file interprets
# the JSON Schema keyword subset documented in the schema's $comment, then
# applies the cross-key rules and the derived defaults that JSON Schema
# cannot express. The resolved configuration contains every key of the
# schema (null where a key has no value and no default).
#
#   load PATH                        -> resolved configuration (throws)
#   loadWith { catalog ? <lib.catalog names>, instanceName ? null } PATH
#   resolve OPTS ATTRS               -> resolved configuration of parsed TOML
#   errors OPTS ATTRS                -> list of messages, [ ] when valid
#   methodFor CFG NAME PLATFORM      -> configured method or null
#
# `catalog` lists the catalog component names (default: the framework's
# modules/components directories). `instanceName` is the default of
# instance.name, the instance directory name, which only the caller knows:
# inside a flake the instance root is a store path. Without either,
# instance.name and the derived instance.checkout are null.
#
# Every error is reported as "dotsteward: workstation.toml: <message>", one
# line per problem, so a user sees all problems of a file at once.
{ lib, dsLib, ... }:
let
  inherit (builtins)
    attrNames
    elem
    filter
    head
    isAttrs
    isBool
    isFloat
    isInt
    isList
    isString
    length
    match
    toJSON
    typeOf
    ;
  inherit (lib)
    concatLists
    concatMap
    concatMapStringsSep
    concatStringsSep
    genAttrs
    imap0
    mapAttrs
    optional
    optionals
    removePrefix
    unique
    ;

  schema = builtins.fromJSON (builtins.readFile ../schema/workstation.schema.json);

  supportedVersion = 1;

  # The public catalog in its canonical order (default of components.order).
  catalogOrder = [
    "shell"
    "herdr"
    "claude-code"
    "codex"
    "opencode-pi"
    "vscode"
  ];

  # Keys of the [profiles] table that are not profile tables.
  profileKeys = [
    "names"
    "default"
    "check"
    "bootstrap"
  ];

  linuxUserPattern = "^[a-z_][a-z0-9_-]*$";

  # --- Messages -------------------------------------------------------------

  # A key path: strings are table keys, integers array indices.
  formatPath =
    path:
    if path == [ ] then
      "(root)"
    else
      lib.foldl' (
        acc: segment:
        if isInt segment then
          "${acc}[${toString segment}]"
        else
          let
            key = if match "[A-Za-z0-9_-]+" segment != null then segment else toJSON segment;
          in
          if acc == "" then key else "${acc}.${key}"
      ) "" path;

  describe =
    value:
    if isAttrs value then
      "a table"
    else if isList value then
      "an array"
    else if isString value then
      "a string"
    else if isInt value then
      "an integer"
    else if isFloat value then
      "a float"
    else if isBool value then
      "a boolean"
    else
      "a ${typeOf value}";

  typeNames = {
    object = "a table";
    array = "an array";
    string = "a string";
    integer = "an integer";
    boolean = "a boolean";
  };

  typeMatches =
    type: value:
    {
      object = isAttrs value;
      array = isList value;
      string = isString value;
      integer = isInt value;
      boolean = isBool value;
    }
    .${type} or (throw "dotsteward: internal error: unsupported schema type ${toJSON type}");

  oneOf = values: concatMapStringsSep ", " toJSON values;

  # --- JSON Schema subset ---------------------------------------------------

  supportedKeywords = [
    "$schema"
    "$id"
    "$defs"
    "$ref"
    "$comment"
    "title"
    "description"
    "default"
    "type"
    "enum"
    "const"
    "pattern"
    "minLength"
    "minimum"
    "maximum"
    "items"
    "minItems"
    "uniqueItems"
    "properties"
    "required"
    "additionalProperties"
    "propertyNames"
  ];

  # Resolves "$ref" (local "#/$defs/<name>" only); keywords next to "$ref"
  # override those of the target.
  deref =
    node:
    let
      unsupported = filter (k: !elem k supportedKeywords) (attrNames node);
      checked =
        if unsupported == [ ] then
          node
        else
          throw "dotsteward: internal error: unsupported schema keywords: ${concatStringsSep ", " unsupported}";
    in
    if checked ? "$ref" then
      let
        name = removePrefix "#/$defs/" checked."$ref";
      in
      if name == checked."$ref" || !(schema."$defs" ? ${name}) then
        throw "dotsteward: internal error: unsupported schema reference ${toJSON checked."$ref"}"
      else
        deref schema."$defs".${name} // removeAttrs checked [ "$ref" ]
    else
      checked;

  # JSON Schema "pattern": an unanchored search, so a pattern constrains a
  # whole value only through its own ^ and $. builtins.match matches whole
  # strings; in a POSIX extended regular expression ^ and $ stay anchors
  # inside a group, so wrapping the pattern keeps their meaning.
  matchesPattern = pattern: value: match ".*(${pattern}).*" value != null;

  plural = n: word: "${toString n} ${word}${if n == 1 then "" else "s"}";

  duplicates = values: unique (filter (v: length (filter (w: w == v) values) > 1) values);

  # validateNode PATH NODE VALUE -> messages
  validateNode =
    path: node: value:
    let
      s = deref node;
      at = formatPath path;
    in
    if s ? type && !(typeMatches s.type value) then
      [ "${at}: expected ${typeNames.${s.type}}, got ${describe value}" ]
    else
      concatLists [
        (optional (s ? const && value != s.const) "${at}: expected ${toJSON s.const}, got ${toJSON value}")
        (optional (
          s ? enum && !(elem value s.enum)
        ) "${at}: expected one of ${oneOf s.enum}, got ${toJSON value}")
        (optional (
          s ? pattern && isString value && !(matchesPattern s.pattern value)
        ) "${at}: ${toJSON value} does not match ${toJSON s.pattern}")
        (optional (s ? minLength && isString value && lib.stringLength value < s.minLength) (
          if s.minLength == 1 then
            "${at}: expected a non-empty string"
          else
            "${at}: expected at least ${plural s.minLength "character"}"
        ))
        (optional (
          s ? minimum && (isInt value || isFloat value) && value < s.minimum
        ) "${at}: expected ${describe value} >= ${toString s.minimum}, got ${toJSON value}")
        (optional (
          s ? maximum && (isInt value || isFloat value) && value > s.maximum
        ) "${at}: expected ${describe value} <= ${toString s.maximum}, got ${toJSON value}")
        (optionals (isList value) (validateArray path s value))
        (optionals (isAttrs value) (validateObject path s value))
      ];

  validateArray =
    path: s: value:
    concatLists [
      (optional (s ? minItems && length value < s.minItems)
        "${formatPath path}: expected at least ${plural s.minItems "item"}, got ${toString (length value)}"
      )
      (optionals (s.uniqueItems or false) (
        map (v: "${formatPath path}: duplicate item ${toJSON v}") (duplicates value)
      ))
      (optionals (s ? items) (concatLists (imap0 (i: v: validateNode (path ++ [ i ]) s.items v) value)))
    ];

  # A key that fails propertyNames: the reason, or null when it is valid.
  keyNameProblem =
    node: key:
    let
      s = deref node;
    in
    if s ? enum && !(elem key s.enum) then
      "expected one of ${oneOf s.enum}"
    else if s ? pattern && !(matchesPattern s.pattern key) then
      "does not match ${toJSON s.pattern}"
    else
      null;

  validateObject =
    path: s: value:
    let
      properties = s.properties or { };
      additional = s.additionalProperties or true;
      # An invalid key name is the only problem reported for that key: the
      # key itself is wrong, so problems of its value would be noise.
      keyErrors =
        key:
        let
          keyPath = path ++ [ key ];
          problem = if s ? propertyNames then keyNameProblem s.propertyNames key else null;
        in
        if problem != null then
          [ "invalid key name ${formatPath keyPath}: ${problem}" ]
        else if properties ? ${key} then
          validateNode keyPath properties.${key} value.${key}
        else if isAttrs additional then
          validateNode keyPath additional value.${key}
        else if additional == false then
          [ "unknown key ${formatPath keyPath}" ]
        else
          [ ];
    in
    map (key: "missing required key ${formatPath (path ++ [ key ])}") (
      filter (key: !(value ? ${key})) (s.required or [ ])
    )
    ++ concatMap keyErrors (attrNames value);

  # --- Static defaults --------------------------------------------------------

  # A missing optional table whose schema has properties is created, so its
  # leaf defaults apply.
  isImplicitTable =
    node:
    let
      s = deref node;
    in
    (s.type or null) == "object" && s ? properties && !(s ? default);

  applyDefaults =
    node: value:
    let
      s = deref node;
    in
    if isAttrs value && (s.type or null) == "object" then
      let
        properties = s.properties or { };
        additional = s.additionalProperties or true;
        required = s.required or [ ];
        known = lib.concatMapAttrs (
          key: child:
          if value ? ${key} then
            { ${key} = applyDefaults child value.${key}; }
          else if (deref child) ? default then
            { ${key} = (deref child).default; }
          else if isImplicitTable child && !(elem key required) then
            { ${key} = applyDefaults child { }; }
          else
            { }
        ) properties;
        extra = mapAttrs (_: v: if isAttrs additional then applyDefaults additional v else v) (
          removeAttrs value (attrNames properties)
        );
      in
      extra // known
    else if isList value && s ? items then
      map (applyDefaults s.items) value
    else
      value;

  # --- Configuration ----------------------------------------------------------

  defaultCatalog = attrNames dsLib.catalog;

  # Catalog names in canonical order, unknown ones sorted after them.
  orderCatalog =
    catalog:
    filter (n: elem n catalog) catalogOrder
    ++ lib.sort lib.lessThan (filter (n: !(elem n catalogOrder)) catalog);

  versionErrors =
    raw:
    if !(raw ? schema_version) then
      [ "missing required key schema_version" ]
    else if !(isInt raw.schema_version) then
      [ "schema_version: expected an integer, got ${describe raw.schema_version}" ]
    else if raw.schema_version != supportedVersion then
      [
        "schema_version ${toString raw.schema_version} is not supported; this dotsteward reads schema_version ${toString supportedVersion} (update the dotsteward flake input to a release that reads it)"
      ]
    else
      [ ];

  # Rules across keys; only run on a schema-valid file.
  semanticErrors =
    { catalog }:
    raw:
    let
      catalogNames = orderCatalog catalog;
      names = raw.profiles.names;
      systems = raw.nix.systems or schema.properties.nix.properties.systems.default;
      username = raw.identity.username;
      components = raw.components or { };
      tables = removeAttrs components [ "order" ];
      notAProfile = path: value: "${formatPath path}: ${toJSON value} is not in profiles.names";

      identityErrors = optional (
        lib.any (lib.hasSuffix "-linux") systems && match linuxUserPattern username == null
      ) "identity.username: ${toJSON username} is not a valid Linux user name (${linuxUserPattern})";

      profileErrors =
        concatLists (
          imap0 (
            i: name:
            optional (elem name profileKeys) "profiles.names[${toString i}]: ${toJSON name} is reserved (profiles.names, default, check and bootstrap are keys of [profiles])"
          ) names
        )
        ++ concatMap (
          role:
          optional (raw.profiles ? ${role} && !(elem raw.profiles.${role} names)) (
            notAProfile [ "profiles" role ] raw.profiles.${role}
          )
        ) (lib.tail profileKeys)
        ++ map (
          key:
          "unknown key ${
            formatPath [
              "profiles"
              key
            ]
          } (not a profile in profiles.names)"
        ) (filter (key: !(elem key profileKeys) && !(elem key names)) (attrNames raw.profiles));

      componentErrors = concatMap (
        name:
        if name == "order" then
          concatLists (
            imap0 (
              i: entry:
              optional (!(elem entry catalogNames) && !(tables ? ${entry}))
                "components.order[${toString i}]: unknown component name ${toJSON entry} (neither a catalog component nor a [components.${entry}] table)"
            ) components.order
          )
        else
          let
            table = tables.${name};
          in
          optional ((table.source or null) == "catalog" && !(elem name catalogNames))
            "components.${name}.source: ${name} is not a catalog component (catalog: ${concatStringsSep ", " catalogNames})"
          ++ concatLists (
            imap0 (
              i: profile:
              optional (!(elem profile names)) (notAProfile [ "components" name "profiles" i ] profile)
            ) (table.profiles or [ ])
          )
      ) (attrNames components);

      aliases = raw.compat.check_aliases or { };
      builtinChecks = [ "home" ] ++ map (name: "home-${name}") names;
      compatErrors = concatMap (
        alias:
        let
          path = [
            "compat"
            "check_aliases"
            alias
          ];
        in
        optional (!(elem aliases.${alias} names)) (notAProfile path aliases.${alias})
        ++ optional (elem alias builtinChecks) "${formatPath path}: collides with the built-in check ${alias}"
      ) (attrNames aliases);
    in
    identityErrors ++ profileErrors ++ componentErrors ++ compatErrors;

  errors =
    {
      catalog ? defaultCatalog,
      ...
    }:
    raw:
    let
      version = versionErrors raw;
      schemaErrors = validateNode [ ] schema raw;
    in
    if version != [ ] then
      version
    else if schemaErrors != [ ] then
      schemaErrors
    else
      semanticErrors { inherit catalog; } raw;

  build =
    {
      catalog ? defaultCatalog,
      instanceName ? null,
    }:
    raw:
    let
      c = applyDefaults schema raw;
      catalogNames = orderCatalog catalog;
      username = c.identity.username;

      names = c.profiles.names;
      defaultProfile = c.profiles.default or (head names);
      profileSchema = schema."$defs".profile;

      name = c.instance.name or instanceName;

      componentSchema = schema."$defs".component;
      tables = removeAttrs c.components [ "order" ];
      instanceNames = lib.sort lib.lessThan (filter (n: !(elem n catalogNames)) (attrNames tables));
      defaultOrder = catalogNames ++ instanceNames;
      givenOrder = c.components.order or [ ];
      order = givenOrder ++ filter (n: !(elem n givenOrder)) defaultOrder;
      componentFor =
        n:
        let
          table = tables.${n} or (applyDefaults componentSchema { });
        in
        table
        // {
          source = table.source or (if elem n catalogNames then "catalog" else "instance");
        };
    in
    c
    // {
      identity = c.identity // {
        home = c.identity.home or "/home/${username}";
        darwin_home = c.identity.darwin_home or "/Users/${username}";
      };
      instance = c.instance // {
        inherit name;
        checkout = c.instance.checkout or (if name == null then null else "~/${name}");
      };
      profiles =
        c.profiles
        // {
          default = defaultProfile;
          check = c.profiles.check or defaultProfile;
          bootstrap = c.profiles.bootstrap or defaultProfile;
        }
        // genAttrs names (n: c.profiles.${n} or (applyDefaults profileSchema { }));
      components = genAttrs (catalogNames ++ instanceNames) componentFor // {
        inherit order;
      };
      settings = c.settings // {
        published_ref = c.settings.published_ref or "origin/${c.instance.branch}";
      };
      # Derived from the machine at run time by the CLI when unset.
      gate = c.gate // {
        nix_max_jobs = c.gate.nix_max_jobs or null;
        nix_cores = c.gate.nix_cores or null;
      };
    };

  resolve =
    opts: raw:
    let
      problems = errors opts raw;
    in
    if problems != [ ] then
      throw (concatMapStringsSep "\n" (message: "dotsteward: workstation.toml: ${message}") problems)
    else
      build opts raw;

  loadWith = opts: path: resolve opts (builtins.fromTOML (builtins.readFile path));
in
{
  inherit
    schema
    catalogOrder
    errors
    resolve
    loadWith
    ;

  load = loadWith { };

  # methodFor CFG NAME PLATFORM: the method configured for a component on a
  # platform ("linux" or "darwin"): method_by_platform, then method; null
  # means the component's own default.
  methodFor =
    cfg: name: platform:
    let
      component = cfg.components.${name} or (throw "dotsteward: unknown component name ${toJSON name}");
      byPlatform = component.method_by_platform.${platform} or null;
    in
    if byPlatform != null then byPlatform else component.method;
}
