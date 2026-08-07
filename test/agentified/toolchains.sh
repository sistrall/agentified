#!/bin/bash
# Empirical profile verification.
#
# Every other test asks "does the allowlist contain what we put in it?" — which
# cannot catch a profile that is missing something. This one asks the only
# question that can: run the real toolchains behind the boundary, then check
# whether the policy had to refuse anything.
#
# An empty `agentified denied` after a real `npm install` is evidence the node
# profile is complete. A non-empty one names exactly what is missing. This is
# the check that would have caught `platform.claude.com` before a user did.
set -e
# shellcheck source=/dev/null  # injected by the harness; only exists inside the test container
source dev-container-features-test-lib
source "$(dirname "$0")/_shared.sh"

# Restart so the proxy log is empty: we want to judge the toolchains, not
# whatever happened during container setup.
check "reset the proxy log" sudo agentified start

check "npm install"  bash -c "cd /tmp && npm install --no-save --no-fund --no-audit chalk >/dev/null && echo ok"
check "pip download" bash -c "python3 -m pip download --quiet --dest /tmp/pipdl requests >/dev/null && echo ok"
check "gem install"  bash -c "gem install --no-document --user-install rake >/dev/null && echo ok"

# The assertion that does the verifying.
# shellcheck disable=SC2016  # this is a script for the inner shell to expand, not us
check "no host was refused while using real toolchains" bash -c '
  denied="$(sudo agentified denied)"
  if [ -n "$denied" ]; then
    echo "These hosts were refused while running real package managers:"
    echo "$denied" | sed "s/^/    /"
    echo
    echo "Either add them to the matching profile in src/agentified/files/profiles/,"
    echo "or decide they should stay blocked and say so in that file."
    exit 1
  fi
  echo "nothing was refused"
'

reportResults
