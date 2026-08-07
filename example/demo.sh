#!/usr/bin/env bash
#
# A two-second tour of the boundary agentified puts around this container.
#
#   ./demo.sh
#
# Each step states what it expects *before* running, then checks it. A step that
# behaves unexpectedly is reported as a failure — a demo that always prints
# green would not be telling you anything.
set -u

bold=$'\033[1m'; dim=$'\033[90m'; green=$'\033[32m'; red=$'\033[31m'; cyan=$'\033[36m'; off=$'\033[0m'
failures=0

step() { printf '\n%s%s%s\n' "$bold" "$1" "$off"; }
cmd()  { printf '%s  $ %s%s\n' "$dim" "$1" "$off"; }
good() { printf '  %s✓%s %s\n' "$green" "$off" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$red" "$off" "$1"; failures=$((failures + 1)); }
note() { printf '    %s%s%s\n' "$dim" "$1" "$off"; }

printf '\n%sagentified demo%s — is the network boundary really there?\n' "$bold" "$off"

if [ -z "${https_proxy:-}" ]; then
  printf '\n%s✗%s https_proxy is not set in this shell.\n' "$red" "$off"
  note 'Open a new terminal, or see docs/adr/0009-keep-proxy-settings-out-of-containerenv.md'
  exit 1
fi
note "proxy in this shell: $https_proxy"

# ---------------------------------------------------------------------------
step '1. Your toolchain still works.'
cmd 'curl https://api.github.com/'
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://api.github.com/ 2>/dev/null)"
if [ "$code" = "200" ]; then
  good "HTTP $code — github.com is on your allowlist, so the proxy let it through"
else
  bad "expected HTTP 200, got '${code:-no response}'"
fi

# ---------------------------------------------------------------------------
step '2. A compromised dependency tries to phone home.'
cmd 'curl https://example.com/     # pretend this is the attacker'
if err="$(curl -sS -o /dev/null --max-time 20 https://example.com/ 2>&1)"; then
  bad "it got through — the allowlist is not being enforced"
else
  good "blocked — example.com is not on your allowlist"
  note "${err#curl: }"
fi

# ---------------------------------------------------------------------------
step '3. So it skips the proxy and connects directly.'
cmd "curl --noproxy '*' https://api.github.com/"
if err="$(curl -sS --noproxy '*' -o /dev/null --max-time 20 https://api.github.com/ 2>&1)"; then
  bad "it got through — the firewall is not enforcing anything"
else
  good "blocked by the firewall — even though github.com IS allowed"
  note "${err#curl: }"
  printf '    %s^ this is the one that matters. The proxy is advisory; a program can%s\n' "$cyan" "$off"
  printf '    %s  ignore it. The firewall is what makes it non-bypassable.%s\n' "$cyan" "$off"
fi

# ---------------------------------------------------------------------------
step '4. Your policy wrote down what it stopped.'
cmd 'sudo agentified denied'
denied="$(sudo agentified denied 2>/dev/null)"
if printf '%s' "$denied" | grep -q 'example\.com'; then
  good "recorded:"
  printf '%s' "$denied" | sed 's/^/      /'
  printf '\n'
  note 'example.com is the one you just triggered. Anything else in that list is'
  note 'real traffic something in this container tried while you were working —'
  note 'editor telemetry, Copilot, cloud metadata probes. Nobody allowed those,'
  note 'so nobody got them. Add what you actually want to the "allow" option.'
else
  bad "expected example.com in the denied list, got: ${denied:-(empty)}"
fi

# ---------------------------------------------------------------------------
if [ "$failures" -eq 0 ]; then
  printf '\n%sAll four steps behaved exactly as intended.%s\n' "$green" "$off"
  printf 'Next: %ssudo agentified status%s for the full picture, or %ssudo agentified verify%s for ~20 more assertions.\n\n' \
    "$cyan" "$off" "$cyan" "$off"
else
  printf '\n%s%s step(s) did not behave as expected.%s Run %ssudo agentified status%s to see why.\n\n' \
    "$red" "$failures" "$off" "$cyan" "$off"
  exit 1
fi
