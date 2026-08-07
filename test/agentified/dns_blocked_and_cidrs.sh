#!/bin/bash
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

check "verify suite"                     sudo agentified verify
check "extraCidr rule present"           bash -c "sudo iptables -S AGENTIFIED_OUT | grep -q '10.99.0.0/16 -j ACCEPT'"
check "no DNS accept rules"              bash -c "! sudo iptables -S AGENTIFIED_OUT | grep -q 'dport 53'"
expect_blocked "workspace user cannot resolve directly" \
                                         dig +time=3 +tries=1 @8.8.8.8 example.com +short
check "the proxy can still resolve"      curl_proxied https://api.github.com/

reportResults
