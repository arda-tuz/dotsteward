# Instance Home Manager module: starship settings and instance blocks placed
# between the shell defaults the way an instance extends .zshrc (3.6).
{
  programs.starship.settings = {
    add_newline = false;
    format = "$directory$git_branch$character";
    character.success_symbol = "[>](bold green)";
  };

  dotsteward.shell.zshrc.blocks = {
    keybindings = {
      order = 45;
      attachToPrevious = true;
      text = ''
        bindkey -e
        bindkey '^F' autosuggest-accept
      '';
    };
    aliases = {
      order = 50;
      text = ''
        alias ..='cd ..'
        alias gs='git status'
      '';
    };
    example-env = {
      order = 80;
      text = ''
        if [[ -d "$HOME/.example" ]]; then
          export EXAMPLE_HOME="$HOME/.example"
          path=("$EXAMPLE_HOME/bin" $path)
        fi
      '';
    };
  };
}
