#!/bin/bash
# off: proxy still runs so HTTPS_PROXY resolves, but nothing is enforced.
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

check "verify suite"                sudo agentified verify
check "OUTPUT policy is ACCEPT"     bash -c "sudo iptables -S OUTPUT | grep -q '^-P OUTPUT ACCEPT'"
check "no agentified chain"        bash -c "! sudo iptables -S AGENTIFIED_OUT >/dev/null 2>&1"
check "direct egress works"         curl_direct  https://example.com/
check "proxied egress works"        curl_proxied https://example.com/
# mode=off asks for no boundary, so a shell warning about there being none is
# noise, not information. The hook is not written at all in this mode.
check "no boundary warning is installed" \
                                    bash -c "! grep -q shell-warning /etc/profile.d/90-agentified.sh"

reportResults
