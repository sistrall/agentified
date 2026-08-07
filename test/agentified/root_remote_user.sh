#!/bin/bash
# remoteUser=root: the sudoers grant is irrelevant and REMOTE_USER_HOME is /root.
# This is the configuration that most often breaks a Feature's assumptions.
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

check "running as root"              bash -c "[ \"\$(id -u)\" -eq 0 ]"
check "config records root"          bash -c "grep -q '^REMOTE_USER=root$' /etc/agentified/config"
check "verify suite"                 agentified verify
check "state volume owned by root"   bash -c "[ -O /agent-state ]"

reportResults
