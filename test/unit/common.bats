#!/usr/bin/env bats

load helper

setup() { load_ag; }

@test "ag_split_csv trims, drops empties and tolerates trailing commas" {
  run ag_split_csv " a , b,,c, "
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "a" ]
  [ "${lines[1]}" = "b" ]
  [ "${lines[2]}" = "c" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "ag_split_csv on empty input produces nothing" {
  run ag_split_csv ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ag_valid_host accepts hostnames and the subdomain marker" {
  for h in github.com api.github.com .githubusercontent.com a-b.example.co.uk x.y.z localhost; do
    run ag_valid_host "$h"
    [ "$status" -eq 0 ] || { echo "rejected valid host: $h"; return 1; }
  done
}

@test "ag_valid_host rejects regex and shell metacharacters" {
  # This is the load-bearing test for the whole option-parsing surface: the
  # `allow` string goes straight into a regex file and into iptables rules.
  for h in '' '.' '*' 'a b' 'a|b' 'a$b' 'evil.com|.*' '(a)' 'a..b' '-a.com' 'a.com-' \
           'a;rm -rf /' 'a
b' '$(id)' '`id`' 'a/b'; do
    run ag_valid_host "$h"
    [ "$status" -ne 0 ] || { echo "accepted invalid host: '$h'"; return 1; }
  done
}

@test "ag_valid_host rejects over-long names" {
  run ag_valid_host "$(printf 'a%.0s' $(seq 1 254))"
  [ "$status" -ne 0 ]
}

@test "ag_valid_cidr accepts addresses and prefixes" {
  for c in 10.0.0.0/8 172.17.0.2 192.168.1.0/24 0.0.0.0/0 255.255.255.255/32; do
    run ag_valid_cidr "$c"
    [ "$status" -eq 0 ] || { echo "rejected valid CIDR: $c"; return 1; }
  done
}

@test "ag_valid_cidr rejects malformed input" {
  for c in '' '10.0.0' '10.0.0.0/33' '10.0.0.256' 'a.b.c.d' '10.0.0.0/x' '::1' '10.0.0.0/8 -j ACCEPT'; do
    run ag_valid_cidr "$c"
    [ "$status" -ne 0 ] || { echo "accepted invalid CIDR: '$c'"; return 1; }
  done
}

@test "ag_valid_port bounds" {
  run ag_valid_port 3128;  [ "$status" -eq 0 ]
  run ag_valid_port 1;     [ "$status" -eq 0 ]
  run ag_valid_port 65535; [ "$status" -eq 0 ]
  run ag_valid_port 0;     [ "$status" -ne 0 ]
  run ag_valid_port 65536; [ "$status" -ne 0 ]
  run ag_valid_port abc;   [ "$status" -ne 0 ]
  run ag_valid_port '';    [ "$status" -ne 0 ]
}
