# Tracking of agent plugins: the trackAt and watched keys of the plugins
# option of a catalog component (claude-code, codex).
#
#   trackAt = "<versions.lock.json path>"   an entry with source (the GitHub
#                                           URL of the marketplace) and
#                                           observed_marketplace_revision (the
#                                           40-digit commit last reviewed)
#   watched = ["<path pattern>", ...]       full-match regular expressions of
#                                           the marketplace paths of the plugin
#
# Each tracked plugin becomes a git-compare row of `dotsteward pins latest`:
# a review when the marketplace changed a watched path since the observed
# revision.
#
# Usage, in a component module with the instance lock `pins`:
#   tracking = dotsteward.lib.pluginTracking { inherit pins; };
#   tracking.keys                 [ "trackAt" "watched" ]
#   tracking.problems AT PLUGIN   the problems of one plugin table, each
#                                 message starting with AT
#                                 ("options.plugins[<index>]")
#   tracking.latest PLUGINS       the latest declarations of the valid
#                                 tracked plugins of a list
{ lib, ... }:
{ pins }:
let
  inherit (builtins)
    isAttrs
    isList
    isString
    match
    toJSON
    ;

  githubUrlPattern = "https://github[.]com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+";
  lockPathPattern = "[A-Za-z0-9_][A-Za-z0-9_+-]*([.][A-Za-z0-9_][A-Za-z0-9_+-]*)*";
  isLockPath = value: isString value && match lockPathPattern value != null;
  isPatternList =
    value: isList value && value != [ ] && lib.all (item: isString item && item != "") value;

  # The lock value at a dotted path, or null when the path is missing.
  lockAt =
    path:
    let
      segments = lib.splitString "." path;
    in
    if lib.hasAttrByPath segments pins then { value = lib.getAttrFromPath segments pins; } else null;

  trackProblems =
    at: plugin:
    lib.optionals (plugin ? trackAt) (
      let
        path = plugin.trackAt;
        found = lockAt path;
        entry = found.value;
        source = entry.source or null;
        revision = entry.observed_marketplace_revision or null;
      in
      if !isLockPath path then
        [ "${at}.trackAt must be a versions.lock.json path, got ${toJSON path}" ]
      else if found == null then
        [ "${at}.trackAt: versions.lock.json lacks ${path}" ]
      else if !isAttrs entry then
        [
          "${at}.trackAt: versions.lock.json ${path} must be an entry with source and observed_marketplace_revision"
        ]
      else
        lib.optional (!(isString source && match githubUrlPattern source != null))
          "${at}.trackAt: versions.lock.json ${path}.source must be a GitHub repository URL https://github.com/OWNER/REPO"
        ++
          lib.optional (!(isString revision && match "[0-9a-f]{40}" revision != null))
            "${at}.trackAt: versions.lock.json ${path}.observed_marketplace_revision must be a 40-digit commit"
    );

  watchedProblems =
    at: plugin:
    if plugin ? watched then
      lib.optional (!isPatternList plugin.watched) "${at}.watched must be a list of path patterns"
      ++ lib.optional (!(plugin ? trackAt)) "${at}.watched needs trackAt"
    else
      lib.optional (plugin ? trackAt) "${at}.trackAt needs watched, a non-empty list of path patterns";
in
{
  keys = [
    "trackAt"
    "watched"
  ];

  problems = at: plugin: trackProblems at plugin ++ watchedProblems at plugin;

  # Only valid entries; invalid ones fail the evaluation through the
  # component's assertions.
  latest =
    plugins:
    map
      (plugin: {
        id = plugin.trackAt;
        adapter = "git-compare";
        at = plugin.trackAt;
        repo_at = ".source";
        revision_at = ".observed_marketplace_revision";
        inherit (plugin) watched;
      })
      (
        lib.filter (
          plugin:
          isAttrs plugin
          && plugin ? trackAt
          && isLockPath plugin.trackAt
          && isPatternList (plugin.watched or null)
        ) plugins
      );
}
