#!/usr/bin/env bash
# agentified :: allowlist compilation (pure text -> text).
#
# Input:  profile names + extra hosts
# Output: one POSIX extended regular expression per line, suitable for a
#         tinyproxy `Filter` file with `FilterExtended On`.
#
#   example.com   ->  ^example\.com$          (exactly that host)
#   .example.com  ->  (^|\.)example\.com$     (that host and any subdomain)

# ag_host_to_ere HOST
# Prints the ERE for a single host. Fails on anything that is not a hostname.
ag_host_to_ere() {
  local h="${1-}" body escaped
  h="${h#"${h%%[![:space:]]*}"}"
  h="${h%"${h##*[![:space:]]}"}"
  [ -n "$h" ] || return 1
  case "$h" in '#'*) return 1 ;; esac

  ag_valid_host "$h" || return 1

  body="${h#.}"
  escaped="${body//./\\.}"
  if [ "$h" != "$body" ]; then
    printf '(^|\\.)%s$\n' "$escaped"
  else
    printf '^%s$\n' "$escaped"
  fi
}

# ag_read_profile DIR NAME
# Prints the raw host lines of one profile, comments and blanks stripped.
# Fails (loudly) when the profile does not exist — a typo in `profiles` must
# not silently produce a narrower allowlist than the user asked for.
ag_read_profile() {
  local dir="${1-}" name="${2-}" file line
  case "$name" in
    ''|*[!a-z0-9_-]*) ag_die "invalid profile name: '$name'"; return 1 ;;
  esac
  file="$dir/$name.txt"
  [ -f "$file" ] || { ag_die "unknown profile: '$name' (no $file)"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] && printf '%s\n' "$line"
  done < "$file"
  return 0
}

# ag_collect_hosts DIR PROFILES_CSV ALLOW_CSV
# Prints the deduplicated, sorted set of hostnames from every source.
#
# Accumulates into a variable rather than piping the loops into `sort`: in a
# pipeline the loop body runs in a subshell, so a `return 1` on an invalid host
# would be discarded and replaced by sort's exit status — the allowlist would
# quietly compile with the bad entry dropped instead of failing.
ag_collect_hosts() {
  local dir="${1-}" profiles="${2-}" allow="${3-}"
  local raw="" chunk p h

  while IFS= read -r p; do
    chunk="$(ag_read_profile "$dir" "$p")" || return 1
    [ -n "$chunk" ] && raw+="$chunk"$'\n'
  done < <(ag_split_csv "$profiles")

  while IFS= read -r h; do
    if ! ag_valid_host "$h"; then
      ag_die "invalid host in 'allow': '$h'"
      return 1
    fi
    raw+="$h"$'\n'
  done < <(ag_split_csv "$allow")

  printf '%s' "$raw" | sed '/^[[:space:]]*$/d' | sort -u
  return 0
}

# ag_compile_allowlist DIR PROFILES_CSV ALLOW_CSV
# Prints the finished filter file.
ag_compile_allowlist() {
  local dir="${1-}" profiles="${2-}" allow="${3-}"
  local hosts h
  hosts="$(ag_collect_hosts "$dir" "$profiles" "$allow")" || return 1
  [ -n "$hosts" ] || { ag_die "allowlist is empty; refusing to write a filter that denies everything"; return 1; }
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    ag_host_to_ere "$h" || { ag_die "cannot compile host: '$h'"; return 1; }
  done <<< "$hosts"
  return 0
}

# ag_extract_hosts
# Reads a tinyproxy log on stdin, prints the distinct hosts that were
# *requested* (whether or not they were allowed). Used by `agentified learn`.
ag_extract_hosts() {
  sed -n \
    -e 's|.*CONNECT \([A-Za-z0-9.:_-]*\):[0-9]* HTTP/.*|\1|p' \
    -e 's|.*[A-Z]* http://\([A-Za-z0-9.:_-]*\)[/ ].*|\1|p' \
    | sed -e 's/:[0-9]*$//' \
    | grep -v '^$' \
    | sort -u
}

# ag_extract_denied
# Reads a tinyproxy log on stdin, prints the hosts the filter refused.
ag_extract_denied() {
  sed -n -e 's|.*filtered domain "\([^"]*\)".*|\1|p' \
         -e 's|.*Proxying refused on filtered domain \([A-Za-z0-9._-]*\).*|\1|p' \
    | sort -u
}
