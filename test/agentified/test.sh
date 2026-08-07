#!/bin/bash
# Default options: agents=claude, profiles=base,editor, mode=enforce.
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

check "agentified installed"        bash -c "command -v agentified"
check "preflight"                    sudo agentified preflight
check "status reports the proxy up"  bash -c "sudo agentified status | grep -q 'proxy      : up'"
check "full verify suite"            sudo agentified verify

reportResults
