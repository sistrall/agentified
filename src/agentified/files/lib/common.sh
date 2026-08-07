#!/usr/bin/env bash
# agentified :: shared helpers.
#
# Everything in lib/ is written to be sourceable and side-effect free at load
# time, so the unit tests can exercise it without root, without iptables and
# without a container.

ag_die() {
  printf 'agentified: %s\n' "$*" >&2
  return 1
}

# Split a comma-separated list into one item per line, trimming whitespace and
# dropping empties. Deliberately tolerant of "a, b,,c," style input.
ag_split_csv() {
  local raw="${1-}" item
  local IFS=','
  # shellcheck disable=SC2086 # word splitting on IFS is the point
  for item in $raw; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -n "$item" ] && printf '%s\n' "$item"
  done
  return 0
}

# A hostname we are willing to compile into a regex or an iptables rule.
# Rejecting everything else is what keeps option strings from becoming an
# injection vector into the tinyproxy filter file.
ag_valid_host() {
  local h="${1-}"
  [ -n "$h" ] || return 1
  [ "${#h}" -le 253 ] || return 1
  case "$h" in
    *[!A-Za-z0-9.-]*) return 1 ;;
    -*|*-)            return 1 ;;
    *..*)             return 1 ;;
    .)                return 1 ;;
  esac
  # A single leading dot is the "and all subdomains" marker; strip it and the
  # remainder must still look like a hostname.
  local body="${h#.}"
  [ -n "$body" ] || return 1
  case "$body" in
    .*|*.) return 1 ;;
  esac
  return 0
}

# IPv4 CIDR or bare address.
ag_valid_cidr() {
  local c="${1-}" addr mask o
  [ -n "$c" ] || return 1
  case "$c" in
    */*) addr="${c%%/*}"; mask="${c##*/}" ;;
    *)   addr="$c";       mask=32 ;;
  esac
  case "$mask" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$mask" -le 32 ] || return 1
  local IFS='.'
  # shellcheck disable=SC2206
  local parts=($addr)
  [ "${#parts[@]}" -eq 4 ] || return 1
  for o in "${parts[@]}"; do
    case "$o" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$o" -le 255 ] || return 1
  done
  return 0
}

ag_valid_port() {
  local p="${1-}"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

ag_log() {
  printf '[agentified] %s\n' "$*" >&2
}
