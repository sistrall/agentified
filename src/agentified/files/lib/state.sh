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

# ------------------------------------------------------------ runtime state --
#
# What the boundary was *started* with, as opposed to what the config file says
# it should be. The two differ the moment anyone uses a documented override:
#
#   sudo AGENTIFIED_MODE=learn agentified start
#
# and `status` used to recompute the mode per invocation, so it kept reporting
# `enforce` at a proxy that was permitting every host. See docs/adr/0021.
#
# The record lives next to the rendered ruleset in /run, because it describes
# this run of the container and must not outlive it: a stale file claiming
# `enforce` would be the same lie in a different place.

# ag_render_state MODE FIREWALL DNS_MODE PROFILES ALLOW PORT
#
# FIREWALL is `applied` or `deferred` — `start --proxy-only` brings up the L7
# half and leaves the L3 backstop to postStart, which is a real state to be in
# and a bad one to mistake for the finished article.
ag_render_state() {
  printf 'RUN_MODE=%s\n'     "${1-}"
  printf 'RUN_FIREWALL=%s\n' "${2-}"
  printf 'RUN_DNS_MODE=%s\n' "${3-}"
  printf 'RUN_PROFILES=%s\n' "${4-}"
  printf 'RUN_ALLOW=%s\n'    "${5-}"
  printf 'RUN_PORT=%s\n'     "${6-}"
  return 0
}

# ag_state_get FILE KEY -- print one value; fail if the file or the key is absent.
#
# Parsed by prefix rather than sourced. The values include user-supplied option
# strings, and this file is read by an unprivileged `status`; `.` on it would
# turn a profile list into something that executes.
ag_state_get() {
  local file="${1-}" key="${2-}" line
  [ -n "$key" ] || return 1
  [ -r "$file" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s\n' "${line#"$key="}"; return 0 ;;
    esac
  done < "$file"
  return 1
}
