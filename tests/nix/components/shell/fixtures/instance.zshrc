autoload -Uz compinit && compinit

HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt APPEND_HISTORY HIST_IGNORE_DUPS SHARE_HISTORY

typeset -U path PATH
path=("$HOME/.local/bin" $path)
export PATH

source @AUTOSUGGESTIONS@/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source @SYNTAX_HIGHLIGHTING@/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
bindkey -e
bindkey '^F' autosuggest-accept

alias ..='cd ..'
alias gs='git status'

if [[ -d "$HOME/.nix-profile/bin" ]]; then
  path=("$HOME/.nix-profile/bin" $path)
fi

if [[ -d "$HOME/.example" ]]; then
  export EXAMPLE_HOME="$HOME/.example"
  path=("$EXAMPLE_HOME/bin" $path)
fi

if [[ $TERM != dumb ]]; then
  eval "$(starship init zsh)"
fi
