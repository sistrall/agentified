#!/usr/bin/env bats

load helper

setup() { load_ag; }

conf() { ag_render_proxy_conf "${1:-enforce}" "${2:-3128}" /etc/agentified/allowlist.filter /var/log/agentified/proxy.log /run/agentified/tinyproxy.pid; }

@test "enforce mode turns the filter file into an allowlist" {
  output="$(conf enforce)"
  assert_contains "$output" "FilterDefaultDeny Yes"
  assert_contains "$output" 'Filter "/etc/agentified/allowlist.filter"'
  assert_contains "$output" "FilterExtended On"
  assert_contains "$output" "FilterCaseSensitive Off"
}

@test "learn mode omits the filter entirely rather than flipping FilterDefaultDeny" {
  # With FilterDefaultDeny No, tinyproxy treats the same file as a *blocklist* —
  # so naively flipping the flag would block exactly the hosts we allow.
  output="$(conf learn)"
  assert_not_contains "$output" "Filter \""
  assert_not_contains "$output" "FilterDefaultDeny"
}

@test "off mode also omits the filter" {
  output="$(conf off)"
  assert_not_contains "$output" "FilterDefaultDeny"
}

@test "every mode logs connections so learn output is available" {
  for m in enforce learn off; do
    output="$(conf "$m")"
    assert_contains "$output" "LogLevel Connect"
  done
}

@test "the proxy listens on loopback only" {
  output="$(conf)"
  assert_contains "$output" "Listen 127.0.0.1"
  assert_contains "$output" "Allow 127.0.0.1"
}

@test "CONNECT is restricted to 80 and 443" {
  # Without ConnectPort lines tinyproxy allows CONNECT to any port, which turns
  # the proxy into an SSH tunnel and an arbitrary-TCP exfiltration path.
  output="$(conf)"
  assert_contains "$output" "ConnectPort 443"
  assert_contains "$output" "ConnectPort 80"
  [ "$(grep -c '^ConnectPort' <<< "$output")" -eq 2 ]
}

@test "the proxy drops privileges to the agentproxy user" {
  # The whole L3 backstop keys off this uid.
  output="$(conf)"
  assert_contains "$output" "User agentproxy"
  assert_contains "$output" "Group agentproxy"
}

@test "the configured port is honoured" {
  output="$(conf enforce 8888)"
  assert_contains "$output" "Port 8888"
}

@test "an invalid port fails rendering" {
  run conf enforce 99999
  [ "$status" -ne 0 ]
  assert_contains "$output" "invalid proxy port"
}

@test "an unknown mode fails rendering" {
  run conf sideways 3128
  [ "$status" -ne 0 ]
  assert_contains "$output" "unknown mode"
}
