# Instance Home Manager module, appended by mkInstance after the components:
# the starship settings (the shell component links starship.toml only when
# the instance sets some).
{
  programs.starship.settings = {
    add_newline = false;
    character.success_symbol = "[>](bold green)";
  };
}
