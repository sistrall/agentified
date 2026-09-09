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
# The guarantee containerEnv buys, and the one a login-shell probe cannot see:
# every process gets the proxy, not just the ones the devcontainer tooling
# starts. A process that misses it egresses directly, is dropped by L3, and
# leaves `agentified denied` empty — the boundary looks broken rather than
# narrow (docs/adr/0024). PID 1 carries exactly what `docker run -e` applied;
# it is root-owned, hence sudo.
check "the proxy is in the container environment, not only in shells" \
                                        sudo bash -c "tr '\\0' '\\n' < /proc/1/environ | grep -qx 'https_proxy=http://127.0.0.1:3128'"
check "extra allow host compiled"       bash -c "sudo agentified hosts | grep -q '\\^rubygems\\\\.org\\$'"
check "subdomain form compiled"         bash -c "sudo agentified hosts | grep -q '(\\^|\\\\.)example\\\\.org\\$'"
check "allowed extra host reachable"    curl_proxied https://rubygems.org/
expect_blocked "unlisted host refused"  curl_proxied https://example.com/
expect_blocked "direct egress blocked"  curl_direct  https://rubygems.org/
check "denied hosts are reported"       bash -c "sudo agentified denied | grep -q example.com"

# --- what is *running*, not what was configured ------------------------------
# `status` used to print the mode this invocation would apply, so a proxy
# started with an override kept being described as `enforce` while permitting
# everything. These run last: they restart the proxy under a different mode and
# put it back afterwards.
check "status reports the running mode" bash -c "sudo agentified status | grep -qE '^mode +: enforce$'"

sudo AGENTIFIED_MODE=learn agentified start
check "an overridden mode is reported"  bash -c "sudo agentified status | grep -qE '^mode +: learn '"
check "and the config is named too"     bash -c "sudo agentified status | grep -qE '^mode +: learn +\\(config: enforce\\)'"
check "learn mode says it is wide open" bash -c "sudo agentified status | grep -q 'LEARN MODE'"
check "and every new terminal says so"  bash -c "bash -ic true 2>&1 >/dev/null | grep -q 'learn mode'"
expect_blocked "verify fails on a mode mismatch" sudo agentified verify
check "and names the mismatch"          bash -c "sudo agentified verify 2>&1 | grep -q 'the running mode matches the configured mode'"

sudo agentified start
check "back to the configured mode"     bash -c "sudo agentified status | grep -qE '^mode +: enforce$'"

# --- a boundary that never started must not look like a working one ----------
sudo agentified stop
check "status says nothing is running"  bash -c "sudo agentified status | grep -q 'NO BOUNDARY IS RUNNING'"
check "a new shell warns, on stderr"    bash -c "bash -ic true 2>&1 >/dev/null | grep -q 'the egress boundary is NOT running'"
# The hook is also sourced from /etc/zsh/zshenv, which every zsh script reads.
# Anything printed there lands in the middle of scp, rsync and git-over-ssh.
check "a non-interactive shell is silent" bash -c "[ -z \"\$(bash -lc true 2>&1)\" ]"
expect_blocked "verify fails when nothing is running" sudo agentified verify

sudo agentified start
check "and the warning goes away"       bash -c "! bash -ic true 2>&1 >/dev/null | grep -q 'boundary is NOT running'"

reportResults
