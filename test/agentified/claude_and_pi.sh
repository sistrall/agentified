#!/bin/bash
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

check "verify suite"              sudo agentified verify
check "claude runs"               bash -c "claude --version"
check "pi runs"                   bash -c "pi --version"
check "pi state is symlinked"     bash -c "[ \"\$(readlink ~/.pi)\" = /agent-state/pi ]"
check "pi state is writable"      bash -c "touch ~/.pi/.probe && rm ~/.pi/.probe"
check "both agents on PATH"       bash -c "command -v claude && command -v pi"

reportResults
