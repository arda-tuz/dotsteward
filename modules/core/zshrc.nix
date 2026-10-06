# .zshrc blocks (3.6): ordered text blocks rendered byte-exactly into
# dotsteward.shell.zshrc.text. Core only renders; the shell component links
# the text as ~/.zshrc, and components and instance modules add blocks.
#
# Rendering: blocks sorted by order (then name), joined with "\n"; every
# block ends in "\n", so blocks are separated by one blank line, except that
# a block with attachToPrevious = true follows the previous one directly.
{
  config,
  lib,
  ...
}:
let
  blocks = config.dotsteward.shell.zshrc.blocks;

  sorted = lib.sort (a: b: if a.order == b.order then a.name < b.name else a.order < b.order) (
    lib.mapAttrsToList (name: block: block // { inherit name; }) blocks
  );

  checked =
    block:
    if lib.hasSuffix "\n" block.text then
      block.text
    else
      throw "dotsteward: .zshrc block ${block.name} must end with a newline";

  render = lib.concatStrings (
    lib.imap0 (
      index: block: (if index == 0 || block.attachToPrevious then "" else "\n") + checked block
    ) sorted
  );
in
{
  options.dotsteward.shell.zshrc = {
    blocks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            order = lib.mkOption {
              type = lib.types.int;
              description = "Position of the block; lower first, equal orders by name.";
            };
            text = lib.mkOption {
              type = lib.types.str;
              description = "Block text, ending in a newline.";
            };
            attachToPrevious = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Join to the previous block without the blank line.";
            };
          };
        }
      );
      default = { };
      description = "Blocks of ~/.zshrc by name.";
    };

    text = lib.mkOption {
      type = lib.types.str;
      default = render;
      defaultText = lib.literalMD "the rendered blocks";
      readOnly = true;
      description = "The rendered ~/.zshrc text.";
    };
  };
}
