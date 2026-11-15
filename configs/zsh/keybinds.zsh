# Force standard emacs keymap (prevents EDITOR=vim/nvim from hijacking zle into vi-mode)
bindkey -e

# Stop word jumps/deletions at path separators (/, -, ., _) like Bash and code editors
WORDCHARS='*?[]~=&;!#$%^(){}<>'

# Ctrl+Left / Ctrl+Right (xterm/VTE/Windows Terminal + application cursor modes)
bindkey '^[[1;5D' backward-word
bindkey '^[[1;5C' forward-word
bindkey '^[Od'    backward-word
bindkey '^[Oc'    forward-word

# Ctrl+Backspace (GNOME Console/Terminal & Windows Terminal send ^H; CSI-u terminals send ^[[127;5u)
bindkey '^H'        backward-kill-word
bindkey '^[[127;5u' backward-kill-word

# Ctrl+Delete (forward word deletion) + Home/End
bindkey '^[[3;5~' kill-word
bindkey '^[[H'    beginning-of-line
bindkey '^[[F'    end-of-line
