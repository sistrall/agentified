#!/usr/bin/env bash
# agentified :: firewall ruleset rendering.
#
# These functions only ever *print* an iptables-restore ruleset. Nothing here
# touches the kernel, which means the interesting logic — ordering, DNS policy,
# the owner-match backstop — is unit-testable on a laptop with no privileges.
# Applying the result is a two-line job in bin/agentified.
#
# Rendering to iptables-restore rather than firing `iptables -A` per rule also
# makes the change atomic: there is no window in which the policy is DROP but
# the ACCEPT rules have not landed yet.

AG_CHAIN="AGENTIFIED_OUT"

# ag_render_ipv4 PROXY_UID DNS_MODE NAMESERVERS_NL EXTRA_CIDRS_CSV
#
# NAMESERVERS_NL is a newline-separated list of resolver addresses (see
# ag_nameservers). Only IPv4 entries are used here.
ag_render_ipv4() {
  local uid="${1-}" dns_mode="${2-}" nameservers="${3-}" cidrs="${4-}"
  local ns c has_link_local_ns=0

  case "$uid" in
    ''|*[!0-9]*) ag_die "proxy uid must be numeric, got '$uid'"; return 1 ;;
  esac
  case "$dns_mode" in
    resolver-only|blocked|open) ;;
    *) ag_die "unknown dnsMode: '$dns_mode'"; return 1 ;;
  esac

  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    case "$ns" in 169.254.*) has_link_local_ns=1 ;; esac
  done <<< "$nameservers"

  printf '*filter\n'
  printf ':INPUT ACCEPT [0:0]\n'
  printf ':FORWARD DROP [0:0]\n'
  printf ':OUTPUT DROP [0:0]\n'
  printf ':%s - [0:0]\n' "$AG_CHAIN"
  printf -- '-A OUTPUT -j %s\n' "$AG_CHAIN"

  # Loopback first: the proxy lives there, and so does Docker's embedded
  # resolver at 127.0.0.11.
  printf -- '-A %s -o lo -j ACCEPT\n' "$AG_CHAIN"

  # Cloud metadata / link-local. Closed for everyone including the proxy user,
  # because a compromised agent asking the proxy for 169.254.169.254 would
  # otherwise walk straight out with the host's instance credentials.
  # The one exception is a resolver that genuinely lives on link-local.
  if [ "$has_link_local_ns" -eq 1 ]; then
    while IFS= read -r ns; do
      case "$ns" in
        169.254.*)
          printf -- '-A %s -p udp --dport 53 -d %s -j ACCEPT\n' "$AG_CHAIN" "$ns"
          printf -- '-A %s -p tcp --dport 53 -d %s -j ACCEPT\n' "$AG_CHAIN" "$ns"
          ;;
      esac
    done <<< "$nameservers"
  fi
  printf -- '-A %s -d 169.254.0.0/16 -j REJECT --reject-with icmp-port-unreachable\n' "$AG_CHAIN"

  printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$AG_CHAIN"

  case "$dns_mode" in
    resolver-only)
      while IFS= read -r ns; do
        [ -n "$ns" ] || continue
        case "$ns" in 169.254.*) continue ;; esac
        ag_valid_cidr "$ns" || { ag_die "unusable nameserver: '$ns'"; return 1; }
        printf -- '-A %s -p udp --dport 53 -d %s -j ACCEPT\n' "$AG_CHAIN" "$ns"
        printf -- '-A %s -p tcp --dport 53 -d %s -j ACCEPT\n' "$AG_CHAIN" "$ns"
      done <<< "$nameservers"
      ;;
    open)
      printf -- '-A %s -p udp --dport 53 -j ACCEPT\n' "$AG_CHAIN"
      printf -- '-A %s -p tcp --dport 53 -j ACCEPT\n' "$AG_CHAIN"
      ;;
    blocked)
      : # only the proxy resolves, via the owner rule below
      ;;
  esac

  # The load-bearing rule. Only the proxy user may open sockets to the world;
  # tinyproxy decides which hostnames. Everything the agent does has to go
  # through loopback to the proxy.
  printf -- '-A %s -m owner --uid-owner %s -j ACCEPT\n' "$AG_CHAIN" "$uid"

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    ag_valid_cidr "$c" || { ag_die "invalid CIDR in extraCidrs: '$c'"; return 1; }
    printf -- '-A %s -d %s -j ACCEPT\n' "$AG_CHAIN" "$c"
  done < <(ag_split_csv "$cidrs")

  printf -- '-A %s -m limit --limit 10/min -j LOG --log-prefix "agentified-block: " --log-level 4\n' "$AG_CHAIN"
  printf -- '-A %s -j REJECT --reject-with icmp-port-unreachable\n' "$AG_CHAIN"
  printf 'COMMIT\n'
  return 0
}

# ag_render_ipv6 PROXY_UID ALLOW_IPV6
# Closed by default. Opening it only opens it for the proxy user.
ag_render_ipv6() {
  local uid="${1-}" allow="${2-false}"
  case "$uid" in
    ''|*[!0-9]*) ag_die "proxy uid must be numeric, got '$uid'"; return 1 ;;
  esac

  printf '*filter\n'
  printf ':INPUT ACCEPT [0:0]\n'
  printf ':FORWARD DROP [0:0]\n'
  printf ':OUTPUT DROP [0:0]\n'
  printf ':%s - [0:0]\n' "$AG_CHAIN"
  printf -- '-A OUTPUT -j %s\n' "$AG_CHAIN"
  printf -- '-A %s -o lo -j ACCEPT\n' "$AG_CHAIN"
  if [ "$allow" = "true" ]; then
    printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$AG_CHAIN"
    printf -- '-A %s -m owner --uid-owner %s -j ACCEPT\n' "$AG_CHAIN" "$uid"
  fi
  printf -- '-A %s -j REJECT --reject-with icmp6-port-unreachable\n' "$AG_CHAIN"
  printf 'COMMIT\n'
  return 0
}

# ag_render_open
# The `mode=off` / `agentified stop` ruleset: everything permitted.
ag_render_open() {
  printf '*filter\n'
  printf ':INPUT ACCEPT [0:0]\n'
  printf ':FORWARD ACCEPT [0:0]\n'
  printf ':OUTPUT ACCEPT [0:0]\n'
  printf 'COMMIT\n'
}

# ag_nameservers [RESOLV_CONF]
# Newline-separated IPv4 nameservers, in file order.
# shellcheck disable=SC2120  # the path is optional by design; the unit tests pass a fixture
ag_nameservers() {
  local file="${1:-/etc/resolv.conf}"
  [ -r "$file" ] || return 0
  awk '$1 == "nameserver" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2 }' "$file"
}
