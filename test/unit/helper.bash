# Shared bootstrap for the unit tests.
#
# The lib/ files are deliberately free of load-time side effects so they can be
# sourced straight from the repository — no install step, no container image,
# no root. That property is worth preserving; if you ever need to `mkdir` or
# touch the network at source time, put it in bin/agentified instead.

# shellcheck disable=SC2034  # consumed by the .bats files that load this helper
AG_LIB="${BATS_TEST_DIRNAME}/../../src/agentified/files/lib"
AG_PROFILES="${BATS_TEST_DIRNAME}/../../src/agentified/files/profiles"
AG_FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

load_ag() {
  # shellcheck source=../../src/agentified/files/lib/common.sh
  . "$AG_LIB/common.sh"
  # shellcheck source=../../src/agentified/files/lib/allowlist.sh
  . "$AG_LIB/allowlist.sh"
  # shellcheck source=../../src/agentified/files/lib/firewall.sh
  . "$AG_LIB/firewall.sh"
  # shellcheck source=../../src/agentified/files/lib/proxy.sh
  . "$AG_LIB/proxy.sh"
}

assert_contains() {
  if [[ "$1" != *"$2"* ]]; then
    printf 'expected output to contain:\n  %s\ngot:\n%s\n' "$2" "$1" >&2
    return 1
  fi
}

assert_not_contains() {
  if [[ "$1" == *"$2"* ]]; then
    printf 'expected output NOT to contain:\n  %s\ngot:\n%s\n' "$2" "$1" >&2
    return 1
  fi
}

# Index of the first line matching a substring; used to assert rule ordering,
# which is the part of the firewall that is easy to get subtly wrong.
line_index() {
  local haystack="$1" needle="$2" i=0 line
  while IFS= read -r line; do
    i=$((i + 1))
    [[ "$line" == *"$needle"* ]] && { printf '%s\n' "$i"; return 0; }
  done <<< "$haystack"
  return 1
}
