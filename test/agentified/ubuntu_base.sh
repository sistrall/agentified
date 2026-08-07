#!/bin/bash
# Same policy on a non-Debian-bookworm base, to catch package-name drift.
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

check "verify suite"                    sudo agentified verify
check "tinyproxy present"               bash -c "command -v tinyproxy"
expect_blocked "unlisted host refused"  curl_proxied https://example.com/

reportResults
