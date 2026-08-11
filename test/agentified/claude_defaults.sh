#!/bin/bash
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

check "verify suite"                     sudo agentified verify
check "claude runs"                      bash -c "claude --version"
check "claude uses the state volume"     bash -c "[ \"\$CLAUDE_CONFIG_DIR\" = /agent-state/claude ]"
# The line above only proves the *inherited* environment. containerEnv does not
# survive anything that resets it — `su -l`, cron, `sudo -i` — and Claude Code
# then falls back to ~/.claude, off the volume. `env -i` reproduces that reset
# without depending on which tooling built the container.
check "the state volume survives an env reset" \
                                         bash -c "sudo env -i /bin/bash -lc 'echo \$CLAUDE_CONFIG_DIR' | grep -qx /agent-state/claude"
check "anthropic api is allowlisted"     bash -c "sudo agentified hosts | grep -q '\\^api\\\\.anthropic\\\\.com\\$'"
check "reaches the anthropic api"        curl_proxied https://api.anthropic.com/
# Claude Code performs a startup connectivity check against both of these and
# refuses to run if either is refused, so assert them by name.
check "reaches the auth host"            curl_proxied https://platform.claude.com/
check "reaches claude.ai"                curl_proxied https://claude.ai/
check "proxy log records the connection" bash -c "sudo agentified learn | grep -q api.anthropic.com"

reportResults
