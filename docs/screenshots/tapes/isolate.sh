# Sourced by every tape. Points the run at a scratch HOME so muxr only sees the
# throwaway sessions the tapes create — otherwise the pane picker photographs
# whatever real sessions happen to be running on the machine.

# Resolve /tmp through any symlink (it is /private/tmp on macOS) so pane cwds
# under HOME actually match Dir.home and render as ~/... rather than in full.
shot_home="$(cd /tmp && pwd -P)/muxr-screenshot-home"
rm -rf "$shot_home"
export HOME="$shot_home"
export SHELL=/bin/bash
mkdir -p "$HOME/.muxr"

cat > "$HOME/.bashrc" <<'RC'
PS1='\[\e[38;5;117m\]\W\[\e[0m\] \[\e[38;5;245m\]$\[\e[0m\] '
PROMPT_COMMAND=
HISTFILE=
RC

mkdir -p "$HOME/work/api" "$HOME/notes"
