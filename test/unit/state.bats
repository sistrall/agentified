#!/usr/bin/env bats

load helper

setup() {
  load_ag
  # shellcheck source=../../src/agentified/files/lib/state.sh
  . "$AG_LIB/state.sh"
  STATE="$BATS_TEST_TMPDIR/state"
}

@test "the record names the mode that was applied, not the one configured" {
  ag_render_state learn applied resolver-only base,claude "" 3128 > "$STATE"
  [ "$(ag_state_get "$STATE" RUN_MODE)" = "learn" ]
}

@test "every field round-trips, including the empty one" {
  ag_render_state enforce applied blocked base,node "example.com,.cdn.example.com" 8888 > "$STATE"
  [ "$(ag_state_get "$STATE" RUN_FIREWALL)" = "applied" ]
  [ "$(ag_state_get "$STATE" RUN_DNS_MODE)" = "blocked" ]
  [ "$(ag_state_get "$STATE" RUN_PROFILES)" = "base,node" ]
  [ "$(ag_state_get "$STATE" RUN_ALLOW)" = "example.com,.cdn.example.com" ]
  [ "$(ag_state_get "$STATE" RUN_PORT)" = "8888" ]

  ag_render_state enforce applied blocked base "" 3128 > "$STATE"
  [ "$(ag_state_get "$STATE" RUN_ALLOW)" = "" ]
}

@test "--proxy-only is recorded as a distinct state, not as a start" {
  ag_render_state enforce deferred resolver-only base "" 3128 > "$STATE"
  [ "$(ag_state_get "$STATE" RUN_FIREWALL)" = "deferred" ]
}

@test "a missing file or key fails rather than answering" {
  run ag_state_get "$STATE.nope" RUN_MODE
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  ag_render_state enforce applied resolver-only base "" 3128 > "$STATE"
  run ag_state_get "$STATE" RUN_NOTHING
  [ "$status" -ne 0 ]
}

@test "a key is matched whole, so RUN_MODE is not answered by RUN_MODEL" {
  printf 'RUN_MODELLING=nonsense\nRUN_MODE=enforce\n' > "$STATE"
  [ "$(ag_state_get "$STATE" RUN_MODE)" = "enforce" ]
}

# The file holds option strings that came from the user. `status` is meant to
# run without sudo, so an unprivileged process parses it — sourcing it would
# make a profile list executable.
@test "values are parsed, never evaluated" {
  printf 'RUN_PROFILES=base$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" > "$STATE"
  run ag_state_get "$STATE" RUN_PROFILES
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [[ "$output" == 'base$(touch '* ]]
}

@test "a value containing an equals sign keeps it" {
  ag_render_state enforce applied resolver-only base "a=b.example.com" 3128 > "$STATE"
  [ "$(ag_state_get "$STATE" RUN_ALLOW)" = "a=b.example.com" ]
}
