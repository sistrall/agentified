#!/usr/bin/env bash
# Helpers shared by every scenario test.
#
# The `check` function comes from dev-container-features-test-lib, which the
# test harness drops into the working directory. Everything here is layered on
# top of it: `check` reports a named pass/fail, `reportResults` exits non-zero
# if any failed.

# expect_blocked NAME COMMAND...
# The inverse of `check`: passes when the command *fails*. Most of what this
# Feature promises is about things that must not work, and the stock helper
# only knows how to assert success.
expect_blocked() {
  local label="$1"; shift
  local out rc=0
  # `out=$(...)` on its own line would abort the whole script under `set -e`,
  # which is exactly the case we are trying to assert. Capture the status.
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "expected '$*' to fail, but it succeeded: ${out:0:300}"
    check "$label" false
  else
    check "$label" true
  fi
}

# Curl through the proxy / bypassing the proxy, as the workspace user.
curl_proxied() { curl -sS --proxy "http://127.0.0.1:3128" --connect-timeout 5 --max-time 20 -o /dev/null "$@"; }
curl_direct()  { curl -sS --noproxy '*' --connect-timeout 5 --max-time 20 -o /dev/null "$@"; }

# Assert an iptables rule exists in the agentified chain.
rule_present() {
  sudo iptables -S AGENTIFIED_OUT 2>/dev/null | grep -q -- "$1"
}
