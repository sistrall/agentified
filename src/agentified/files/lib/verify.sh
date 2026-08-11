#!/usr/bin/env bash
# agentified :: in-container assertion suite.
#
# Run as root (`sudo agentified verify`), but every network probe is executed
# as the workspace user, because that is the identity the policy is written
# about. Probing as root would tell you about root's egress, not the agent's.
#
# shellcheck disable=SC2016
# Assertions are command *strings* evaluated by that inner shell, so single
# quotes are deliberate throughout: expansion must happen there, not here.
set -uo pipefail

AG_HOME="${AGENTIFIED_HOME:-/usr/local/share/agentified}"
AG_ETC="${AGENTIFIED_ETC:-/etc/agentified}"
AG_RUN="${AGENTIFIED_RUN:-/run/agentified}"

# shellcheck source=common.sh
. "$AG_HOME/lib/common.sh"
# shellcheck source=state.sh
. "$AG_HOME/lib/state.sh"
# shellcheck disable=SC1091
. "$AG_ETC/config"

# Two modes, deliberately. CONFIGURED_MODE is what the config file asks for;
# RUN_MODE is what `start` recorded actually applying. Asserting against the
# configured one made a proxy running in learn mode fail the enforce
# assertions, which reads as "the allowlist is broken" rather than "you are in
# learn mode" — see docs/adr/0021.
CONFIGURED_MODE="${AGENTIFIED_MODE:-${MODE:-enforce}}"
RUN_MODE=""
RUN_FIREWALL=""
PROXY_UP=0
# `agentified running` rather than pgrep: pgrep counts zombies, and nothing
# reaps them when PID 1 is the usual `sleep infinity`, so a proxy that exited
# hours ago would still answer here.
if /usr/local/bin/agentified running 2>/dev/null; then
  PROXY_UP=1
  RUN_MODE="$(ag_state_get "$AG_RUN/state" RUN_MODE || true)"
  RUN_FIREWALL="$(ag_state_get "$AG_RUN/state" RUN_FIREWALL || true)"
fi
MODE="${RUN_MODE:-$CONFIGURED_MODE}"
DNS_MODE="${DNS_MODE:-resolver-only}"
PROXY_PORT="${PROXY_PORT:-3128}"
ALLOW_IPV6="${ALLOW_IPV6:-false}"
REMOTE_USER="${REMOTE_USER:-root}"
PROXY="http://127.0.0.1:$PROXY_PORT"

PASS=0; FAIL=0; SKIP=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
grey()  { printf '\033[90m%s\033[0m' "$1"; }

ok()      { PASS=$((PASS+1)); printf '  %s %s\n' "$(green PASS)" "$1"; }
bad()     { FAIL=$((FAIL+1)); printf '  %s %s\n' "$(red FAIL)" "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
skipped() { SKIP=$((SKIP+1)); printf '  %s %s %s\n' "$(grey SKIP)" "$1" "$(grey "(${2:-})")"; }

# Run a command as the workspace user in a *login* shell.
#
# Login matters: the proxy variables come from /etc/profile.d, and `sudo` has
# already stripped the container environment by the time this script runs. A
# non-login `sh -c` would test an environment no real client ever sees.
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$REMOTE_USER" != "root" ]; then
    su -l "$REMOTE_USER" -c "$1"
  else
    bash -lc "$1"
  fi
}

# assert_ok  DESCRIPTION COMMAND   -- command must succeed
# assert_no  DESCRIPTION COMMAND   -- command must fail
assert_ok() {
  local desc="$1" cmd="$2" out
  if out="$(as_user "$cmd" 2>&1)"; then ok "$desc"; else bad "$desc" "${out:-(no output)}"; fi
}
assert_no() {
  local desc="$1" cmd="$2" out
  if out="$(as_user "$cmd" 2>&1)"; then bad "$desc" "unexpectedly succeeded: ${out:0:200}"; else ok "$desc"; fi
}

CURL_P="curl -sS --proxy $PROXY --connect-timeout 5 --max-time 20 -o /dev/null"
CURL_D="curl -sS --noproxy '*' --connect-timeout 5 --max-time 20 -o /dev/null"

printf '\n== agentified verify (mode=%s dns=%s ipv6=%s) ==\n' "$MODE" "$DNS_MODE" "$ALLOW_IPV6"
if [ -n "$RUN_MODE" ] && [ "$RUN_MODE" != "$CONFIGURED_MODE" ]; then
  printf '   mode is the one the running proxy was started with; the config file says %s\n' "$CONFIGURED_MODE"
fi
printf '\n'

printf 'environment\n'
if [ -x /usr/local/bin/agentified ]; then ok "agentified CLI installed"; else bad "agentified CLI installed"; fi
if /usr/local/bin/agentified preflight >/dev/null 2>&1; then
  ok "preflight (xt_owner, xt_conntrack, NET_ADMIN, tinyproxy)"
else
  bad "preflight" "$(/usr/local/bin/agentified preflight 2>&1)"
fi

printf '\nboundary\n'
# Everything below describes the boundary that is *running*. If none is, say so
# once and plainly: an installed-but-never-started Feature leaves the proxy
# variables exported and nothing listening, which reads as a broken proxy
# rather than as no boundary at all.
if [ "$PROXY_UP" -eq 0 ]; then
  bad "the boundary is running" \
      "no tinyproxy process. Some editors never run a Feature's onCreate/postStart commands, and a container restarted outside the devcontainer tooling does not either — start it with: sudo agentified start"
elif [ -z "$RUN_MODE" ]; then
  ok "proxy process running"
  skipped "the running mode matches the configured mode" "no runtime record; proxy started by an older version?"
else
  ok "proxy process running"
  if [ "$RUN_MODE" = "$CONFIGURED_MODE" ]; then
    ok "the running mode matches the configured mode ($RUN_MODE)"
  else
    bad "the running mode matches the configured mode" \
        "config says '$CONFIGURED_MODE' but the proxy was started in '$RUN_MODE' mode; the assertions below describe '$RUN_MODE'. Re-apply with: sudo agentified start"
  fi
  if [ "$RUN_FIREWALL" = "applied" ]; then
    ok "the firewall backstop was applied at start"
  else
    bad "the firewall backstop was applied at start" \
        "the proxy came up with --proxy-only and nothing completed the job; the L3 assertions below say whether any ruleset survives from an earlier start. Fix with: sudo agentified start"
  fi
fi

printf '\nagents\n'
# An agent installed without its profile starts fine and then cannot reach its
# own API. That reads as "the agent is broken", so name it here instead.
for agent in claude pi; do
  case ",${AGENTS:-}," in
    *",$agent,"*)
      case ",${PROFILES:-}," in
        *",$agent,"*) ;;
        *) bad "the '$agent' profile is enabled" \
               "agents includes '$agent' but profiles is '${PROFILES:-}' — it will not reach its own API" ;;
      esac ;;
  esac
done
case ",${AGENTS:-}," in
  *,claude,*)
    assert_ok "claude on PATH and executable" "command -v claude >/dev/null && claude --version >/dev/null"
    # Read it from the user's environment, not this script's: sudo has already
    # reset the environment that containerEnv populated.
    claude_dir="$(as_user 'echo "${CLAUDE_CONFIG_DIR:-unset}"')"
    if [ "$claude_dir" = "/agent-state/claude" ]; then
      ok "CLAUDE_CONFIG_DIR points at the state volume"
    else
      bad "CLAUDE_CONFIG_DIR points at the state volume" "got '$claude_dir'"
    fi ;;
  *) skipped "claude checks" "not requested" ;;
esac
case ",${AGENTS:-}," in
  *,pi,*)
    assert_ok "pi on PATH and executable" "command -v pi >/dev/null && pi --version >/dev/null"
    assert_ok "pi home directory links into the state volume" \
      '[ "$(readlink "$HOME/.pi")" = /agent-state/pi ]' ;;
  *) skipped "pi checks" "not requested" ;;
esac

printf '\nagent policy (%s)\n' "${AGENT_POLICY:-strict}"
case "${AGENT_POLICY:-strict}" in
  off) skipped "agent policy checks" "agentPolicy=off" ;;
  *)
    if [ -r "$AG_HOME/policy/agent-notes.md" ]; then
      ok "policy notes installed"
    else
      bad "policy notes installed" "missing $AG_HOME/policy/agent-notes.md"
    fi
    case ",${AGENTS:-}," in
      *,claude,*)
        if [ "${AGENT_POLICY:-strict}" = "strict" ]; then
          # Root-owned and not user-writable: the deny list has to survive the
          # agent it constrains.
          if [ -r /etc/claude-code/managed-settings.json ]; then
            ok "Claude Code managed settings installed"
            if [ "$(stat -c '%U %a' /etc/claude-code/managed-settings.json)" = "root 644" ]; then
              ok "managed settings are root-owned and not user-writable"
            else
              bad "managed settings are root-owned and not user-writable" \
                  "got $(stat -c '%U %a' /etc/claude-code/managed-settings.json)"
            fi
            if grep -q 'Bash(sudo \*)' /etc/claude-code/managed-settings.json; then
              ok "sudo is denied to the agent"
            else
              bad "sudo is denied to the agent" "no 'Bash(sudo *)' deny rule"
            fi
          else
            bad "Claude Code managed settings installed" "missing /etc/claude-code/managed-settings.json"
          fi
        else
          skipped "Claude Code deny rules" "agentPolicy=notes-only"
        fi
        if [ -r "${AGENT_STATE_DIR:-/agent-state}/claude/CLAUDE.md" ]; then
          ok "policy notes reach Claude Code as user memory"
        else
          bad "policy notes reach Claude Code as user memory" \
              "no CLAUDE.md in the state volume"
        fi ;;
    esac
    case ",${AGENTS:-}," in
      *,pi,*)
        if grep -q 'append-system-prompt' /usr/local/bin/pi 2>/dev/null; then
          ok "policy notes reach pi via --append-system-prompt"
        else
          bad "policy notes reach pi via --append-system-prompt" "not in the pi wrapper"
        fi ;;
    esac
    # The agent must keep a way to *diagnose* the boundary without sudo,
    # otherwise denying sudo just leaves it stuck instead of informative.
    assert_ok "the agent can read the denied list without sudo" "agentified denied >/dev/null"
    # And that diagnosis has to be truthful. `status` once reported the proxy
    # as DOWN to any unprivileged caller, because tinyproxy's pidfile is
    # 0600 root-owned — which is precisely the false alarm that provokes an
    # agent to start repairing things.
    assert_ok "unprivileged 'status' reports the proxy truthfully" \
      "agentified status | grep -qE '^proxy +: up'"
    ;;
esac

printf '\nproxy environment\n'
# The proxy variables come from /etc/profile.d rather than containerEnv (see
# docs/adr/0009-keep-proxy-settings-out-of-containerenv.md). If userEnvProbe has
# been turned off, clients will not see them and everything will silently
# egress-fail instead of being proxied.
probe_env="$(as_user 'echo "${https_proxy:-unset}"')"
if [ "$probe_env" = "http://127.0.0.1:$PROXY_PORT" ]; then
  ok "https_proxy visible in a login shell ($probe_env)"
else
  bad "https_proxy visible in a login shell" \
      "got '$probe_env'; set userEnvProbe to loginInteractiveShell, or add remoteEnv"
fi

printf '\nstate volume\n'
assert_ok "state volume writable by $REMOTE_USER" "touch /agent-state/.verify && rm -f /agent-state/.verify"

printf '\nL7 (proxy allowlist)\n'
if [ "$MODE" = "enforce" ]; then
  assert_ok "allowed host reachable through the proxy"      "$CURL_P https://api.github.com/"
  assert_no "unlisted host refused by the proxy"            "$CURL_P https://example.com/"
  assert_no "CONNECT to :22 refused (no SSH tunnelling)"    "$CURL_P https://github.com:22/"
  assert_no "CONNECT to :25 refused (no SMTP tunnelling)"   "$CURL_P https://github.com:25/"
else
  skipped "proxy allowlist assertions" "mode=$MODE permits everything by design"
  assert_ok "proxy still forwards traffic"                  "$CURL_P https://api.github.com/"
fi

printf '\nL3 (firewall backstop)\n'
if [ "$MODE" = "off" ]; then
  skipped "firewall assertions" "mode=off"
else
  assert_no "unlisted host unreachable without the proxy"   "$CURL_D https://example.com/"
  assert_no "allowed host ALSO unreachable without the proxy (proves L3 is not hostname-aware)" \
                                                            "$CURL_D https://api.github.com/"
  assert_no "cloud metadata endpoint unreachable"           "curl -sS --noproxy '*' --connect-timeout 3 --max-time 5 -o /dev/null http://169.254.169.254/"
  if command -v ssh >/dev/null 2>&1; then
    assert_no "direct ssh blocked"                          "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes git@github.com"
  else
    skipped "direct ssh blocked" "ssh not installed"
  fi
fi

printf '\nDNS\n'
if ! command -v dig >/dev/null 2>&1; then
  skipped "DNS assertions" "dig not installed"
elif [ "$MODE" = "off" ]; then
  skipped "DNS assertions" "mode=off"
else
  case "$DNS_MODE" in
    resolver-only)
      assert_ok "container resolver still works"            "getent hosts github.com >/dev/null"
      assert_no "arbitrary resolver unreachable"            "dig +time=3 +tries=1 @8.8.8.8 example.com +short" ;;
    blocked)
      assert_no "direct DNS blocked"                        "dig +time=3 +tries=1 @8.8.8.8 example.com +short" ;;
    open)
      assert_ok "arbitrary resolver reachable"              "dig +time=3 +tries=1 @8.8.8.8 example.com +short" ;;
  esac
fi

printf '\nIPv6\n'
if [ ! -f /proc/net/if_inet6 ]; then
  skipped "IPv6 assertions" "no IPv6 stack in this container"
elif [ "$MODE" = "off" ]; then
  skipped "IPv6 assertions" "mode=off"
elif [ "$ALLOW_IPV6" = "true" ]; then
  skipped "IPv6 egress closed" "allowIpv6=true"
else
  assert_no "IPv6 egress closed"                            "$CURL_D -6 https://api.github.com/"
fi

printf '\n%s passed, %s failed, %s skipped\n\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
