#!/bin/bash
# learn: the proxy permits and records everything, but the L3 backstop stays on
# so nothing can observe the world without going through the proxy.
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

check "verify suite"                       sudo agentified verify
check "unlisted host permitted"            curl_proxied https://example.com/
check "it was recorded"                    bash -c "sudo agentified learn | grep -q '^example.com$'"
check "no filter file is referenced"       bash -c "! grep -q FilterDefaultDeny /etc/agentified/tinyproxy.conf"
expect_blocked "L3 backstop still active"  curl_direct https://example.com/
check "OUTPUT policy is still DROP"        bash -c "sudo iptables -S OUTPUT | grep -q '^-P OUTPUT DROP'"

reportResults
