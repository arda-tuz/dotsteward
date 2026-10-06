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

if [[ -d "$HOME/.nix-profile/bin" ]]; then
  path=("$HOME/.nix-profile/bin" $path)
fi

if [[ $TERM != dumb ]]; then
  eval "$(starship init zsh)"
fi
