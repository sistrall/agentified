#!/usr/bin/env bash
# agentified :: persistent agent state.
#
# The Feature mounts a per-devcontainer volume at /agent-state. Agents keep
# credentials in different places, so each one is either pointed at the volume
# through an environment variable (Claude Code) or symlinked into it (Pi, which
# hardcodes ~/.pi).

# ag_link_home_dir USER HOME LINK_NAME TARGET
# Idempotent. Leaves a pre-existing real directory alone rather than destroying
# whatever the user already had there.
ag_link_home_dir() {
  local user="${1-}" home="${2-}" name="${3-}" target="${4-}"
  local link="$home/$name"

  mkdir -p "$target"
  chown "$user" "$target" 2>/dev/null || true

  if [ -L "$link" ]; then
    local current
    current="$(readlink "$link")"
    [ "$current" = "$target" ] && return 0
    ag_log "replacing $link -> $current with $link -> $target"
    rm -f "$link"
  elif [ -e "$link" ]; then
    ag_log "$link already exists and is not a symlink; leaving it alone (state will not persist across rebuilds)"
    return 0
  fi

  ln -s "$target" "$link"
  chown -h "$user" "$link" 2>/dev/null || true
  return 0
}
