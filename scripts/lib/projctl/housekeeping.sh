#!/usr/bin/env sh
# projctl housekeeping: scratch-file cleanup. Sourced by scripts/projctl.
# Function-only.
#
# Deliberately NOT `git clean -X`: that would also wipe gitignored agent
# working dirs (.claude/, docs/superpowers/) that must stay on the workstation.

# Scratch files, matching the patterns in .gitignore, outside .git and the
# agent working dirs.
proj_scratch() {
  find "$PLTFCTL_HOME" \
    \( -path "$PLTFCTL_HOME/.git" -o -path "$PLTFCTL_HOME/.claude" \
       -o -path "$PLTFCTL_HOME/.superpowers" -o -path "$PLTFCTL_HOME/docs/superpowers" \) -prune \
    -o \( -type d -name tmp -prune -print \) \
    -o \( -type f \( -name '*.tmp' -o -name '*.bak' -o -name '*.orig' -o -name '*.log' \) -print \)
}

proj_clean() { # [-f]
  _force=0
  case "${1:-}" in
    '') ;;
    -f) _force=1 ;;
    *)  pltf_die "usage: projctl clean [-f]" ;;
  esac
  _list=$(proj_scratch)
  [ -n "$_list" ] || { pltf_ok "Nothing to clean."; return 0; }
  printf '%s\n' "$_list" | sed "s|^$PLTFCTL_HOME/|  |"
  if [ "$_force" -eq 1 ]; then
    printf '%s\n' "$_list" | while IFS= read -r _p; do rm -rf -- "$_p"; done
    pltf_ok "Removed."
  else
    pltf_info "Dry run. Re-run with -f to delete the above."
  fi
}
