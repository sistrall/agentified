#!/bin/bash
# No agent installed: exercises the network boundary in isolation, including
# the `allow` option and the subdomain form.
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

check "verify suite"                    sudo agentified verify
# Regression: status must not report a running proxy as DOWN to a caller
# without root. It is the command we tell agents to run when things look wrong.
check "status is truthful without sudo" bash -c "agentified status | grep -qE '^proxy +: up'"
check "status says why the rules are hidden without sudo" \
                                        bash -c "agentified status | grep -q 'readable by root only'"
check "no agent was installed"          bash -c "! command -v claude && ! command -v pi"
check "extra allow host compiled"       bash -c "sudo agentified hosts | grep -q '\\^rubygems\\\\.org\\$'"
check "subdomain form compiled"         bash -c "sudo agentified hosts | grep -q '(\\^|\\\\.)example\\\\.org\\$'"
check "allowed extra host reachable"    curl_proxied https://rubygems.org/
expect_blocked "unlisted host refused"  curl_proxied https://example.com/
expect_blocked "direct egress blocked"  curl_direct  https://rubygems.org/
check "denied hosts are reported"       bash -c "sudo agentified denied | grep -q example.com"

reportResults
