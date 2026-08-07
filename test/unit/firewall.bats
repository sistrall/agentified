#!/usr/bin/env bats

load helper

setup() { load_ag; }

render() { ag_render_ipv4 "${1:-999}" "${2:-resolver-only}" "${3:-10.0.0.53}" "${4:-}"; }

@test "the OUTPUT policy is DROP" {
  run render
  [ "$status" -eq 0 ]
  assert_contains "$output" ":OUTPUT DROP [0:0]"
}

@test "only the proxy uid may egress" {
  run render 4242
  assert_contains "$output" "--uid-owner 4242 -j ACCEPT"
}

@test "the ruleset ends in a REJECT so nothing falls through to the policy silently" {
  output="$(render)"
  last_rule="$(grep -- '-A AGENTIFIED_OUT' <<< "$output" | tail -1)"
  assert_contains "$last_rule" "-j REJECT"
}

@test "loopback is accepted before anything else" {
  output="$(render)"
  lo="$(line_index "$output" '-o lo -j ACCEPT')"
  owner="$(line_index "$output" '--uid-owner')"
  [ "$lo" -lt "$owner" ]
}

@test "link-local metadata is rejected even for the proxy user" {
  # 169.254.169.254 hands out the host's cloud credentials. Letting the proxy
  # reach it would make the allowlist irrelevant on any cloud dev machine.
  output="$(render)"
  meta="$(line_index "$output" '169.254.0.0/16')"
  owner="$(line_index "$output" '--uid-owner')"
  established="$(line_index "$output" 'ESTABLISHED,RELATED')"
  [ "$meta" -lt "$owner" ]
  [ "$meta" -lt "$established" ]
}

@test "resolver-only opens DNS to exactly the configured nameservers" {
  output="$(render 999 resolver-only "$(printf '10.0.0.53\n10.0.0.54\n')")"
  assert_contains "$output" '--dport 53 -d 10.0.0.53 -j ACCEPT'
  assert_contains "$output" '--dport 53 -d 10.0.0.54 -j ACCEPT'
  assert_not_contains "$output" '-p udp --dport 53 -j ACCEPT'
}

@test "resolver-only emits both udp and tcp DNS rules" {
  output="$(render 999 resolver-only 10.0.0.53)"
  assert_contains "$output" '-p udp --dport 53 -d 10.0.0.53'
  assert_contains "$output" '-p tcp --dport 53 -d 10.0.0.53'
}

@test "blocked emits no DNS rules at all" {
  output="$(render 999 blocked 10.0.0.53)"
  assert_not_contains "$output" '--dport 53'
}

@test "open allows any resolver" {
  output="$(render 999 open 10.0.0.53)"
  assert_contains "$output" '-p udp --dport 53 -j ACCEPT'
}

@test "a link-local resolver is carved out of the metadata block" {
  # Some runtimes hand out a resolver inside 169.254.0.0/16. Blanket-rejecting
  # the range would break name resolution entirely, so the specific nameserver
  # is permitted on port 53 only, above the range reject.
  output="$(render 999 resolver-only 169.254.0.2)"
  ns="$(line_index "$output" '-d 169.254.0.2')"
  meta="$(line_index "$output" '169.254.0.0/16 -j REJECT')"
  [ "$ns" -lt "$meta" ]
  assert_contains "$output" '--dport 53 -d 169.254.0.2'
}

@test "extraCidrs are appended as direct-egress accepts" {
  output="$(render 999 resolver-only 10.0.0.53 "172.17.0.0/16, 10.5.0.2")"
  assert_contains "$output" '-d 172.17.0.0/16 -j ACCEPT'
  assert_contains "$output" '-d 10.5.0.2 -j ACCEPT'
}

@test "a malformed extraCidr fails rendering rather than producing a broken ruleset" {
  run render 999 resolver-only 10.0.0.53 "172.17.0.0/16,not-a-cidr"
  [ "$status" -ne 0 ]
  assert_contains "$output" "invalid CIDR"
}

@test "an injection attempt through extraCidrs is rejected" {
  run render 999 resolver-only 10.0.0.53 '0.0.0.0/0 -j ACCEPT'
  [ "$status" -ne 0 ]
}

@test "an unknown dnsMode fails rendering" {
  run render 999 sideways 10.0.0.53
  [ "$status" -ne 0 ]
  assert_contains "$output" "unknown dnsMode"
}

@test "a non-numeric uid fails rendering" {
  run render agentproxy resolver-only 10.0.0.53
  [ "$status" -ne 0 ]
}

@test "the ruleset is a well-formed iptables-restore document" {
  output="$(render)"
  [ "$(head -1 <<< "$output")" = "*filter" ]
  [ "$(tail -1 <<< "$output")" = "COMMIT" ]
  assert_contains "$output" ":INPUT ACCEPT"
  assert_contains "$output" ":FORWARD DROP"
  assert_contains "$output" ":AGENTIFIED_OUT - [0:0]"
}

@test "blocked traffic is logged, rate-limited, before the final reject" {
  output="$(render)"
  log="$(line_index "$output" 'agentified-block')"
  rej="$(line_index "$output" '-A AGENTIFIED_OUT -j REJECT')"
  [ "$log" -lt "$rej" ]
  assert_contains "$output" '--limit 10/min'
}

@test "ipv6 is closed by default and opens only for the proxy uid" {
  output="$(ag_render_ipv6 4242 false)"
  assert_contains "$output" ":OUTPUT DROP [0:0]"
  assert_not_contains "$output" "--uid-owner"

  output="$(ag_render_ipv6 4242 true)"
  assert_contains "$output" "--uid-owner 4242 -j ACCEPT"
  assert_contains "$output" ":OUTPUT DROP [0:0]"
}

@test "the open ruleset restores plain ACCEPT policies" {
  output="$(ag_render_open)"
  assert_contains "$output" ":OUTPUT ACCEPT [0:0]"
  assert_not_contains "$output" "REJECT"
}

@test "ag_nameservers reads only IPv4 nameserver lines" {
  run ag_nameservers "$AG_FIXTURES/resolv.conf"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "127.0.0.11" ]
  [ "${lines[1]}" = "8.8.8.8" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "ag_nameservers on a missing file is empty, not an error" {
  run ag_nameservers /nonexistent/resolv.conf
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
