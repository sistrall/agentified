#!/usr/bin/env bash
# agentified :: build-time installer. Runs as root during image build.
#
# Feature options arrive as uppercased environment variables (AGENTS, PROFILES,
# ALLOW, ...). _REMOTE_USER and _REMOTE_USER_HOME are supplied by the Features
# tooling and are needed here because the runtime script has to know whose home
# directory to link state into.
#
# NOTE: this script runs *before* any of the egress rules exist and needs the
# apt mirrors, claude.ai and downloads.claude.ai (Claude Code), and nodejs.org
# and registry.npmjs.org (Pi). "Add the Feature and rebuild" assumes
# unrestricted egress at build time. See README §Limitations.
set -euo pipefail

# If anything upstream exported proxy variables into the build (a corporate
# base image, or a user who added them to containerEnv by hand), they point at
# a proxy that does not exist yet. Our own build must not inherit them.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY

AGENTS="${AGENTS:-claude}"
AGENT_POLICY="${AGENTPOLICY:-strict}"
PROFILES="${PROFILES:-base,claude,editor}"
ALLOW="${ALLOW:-}"
EXTRA_CIDRS="${EXTRACIDRS:-}"
DNS_MODE="${DNSMODE:-resolver-only}"
MODE="${MODE:-enforce}"
PROXY_PORT="${PROXYPORT:-3128}"
ALLOW_IPV6="${ALLOWIPV6:-false}"
INSTALL_NODE_IF_MISSING="${INSTALLNODEIFMISSING:-true}"

REMOTE_USER="${_REMOTE_USER:-root}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-/root}"

SHARE=/usr/local/share/agentified
ETC=/etc/agentified
OPT=/opt/agentified
STATE="${AGENTIFIED_STATE:-/agent-state}"
NODE_VERSION=22.20.0

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n[agentified/install] %s\n' "$*"; }

# True when the `agents` option names the given agent.
wants() { case ",$AGENTS," in *",$1,"*) return 0 ;; esac; return 1; }

# Run a command as the workspace user. Anything that has to live in that
# user's home — and be writable by them afterwards — is installed this way
# rather than as root and chowned, so the result is exactly what the user
# would have got running the same installer themselves.
as_remote_user() {
  if [ "$REMOTE_USER" = root ]; then "$@"; else runuser -u "$REMOTE_USER" -- "$@"; fi
}

# --------------------------------------------------------------- packages ---

log "installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl iptables iproute2 procps sudo tinyproxy dnsutils \
  openssh-client xz-utils
rm -rf /var/lib/apt/lists/*

# Debian's tinyproxy package ships an /etc/tinyproxy/tinyproxy.conf and, on some
# images, an init script that would start a second, unfiltered instance.
systemctl disable tinyproxy 2>/dev/null || true
rm -f /etc/init.d/tinyproxy 2>/dev/null || true

# ------------------------------------------------------------ private node ---

# Only Pi is a Node program. Claude Code ships as a native binary and is
# installed below without npm, so `agents: claude` on an image with no Node
# installs no Node either.
need_node() {
  local bin major
  bin="$(command -v node || true)"
  [ -n "$bin" ] || return 0
  major="$("$bin" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "$major" -ge 22 ] && return 1
  return 0
}

NODE_DIR=""
if wants pi && need_node; then
  if [ "$INSTALL_NODE_IF_MISSING" != "true" ]; then
    echo "agentified: no Node >= 22 found and installNodeIfMissing=false" >&2
    exit 1
  fi
  log "installing a private Node $NODE_VERSION under $OPT (project toolchain untouched)"
  case "$(dpkg --print-architecture)" in
    amd64) NARCH=x64 ;;
    arm64) NARCH=arm64 ;;
    *) echo "agentified: unsupported architecture $(dpkg --print-architecture)" >&2; exit 1 ;;
  esac
  TARBALL="node-v${NODE_VERSION}-linux-${NARCH}.tar.xz"
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/$TARBALL"    "https://nodejs.org/dist/v${NODE_VERSION}/${TARBALL}"
  curl -fsSL -o "$TMP/SHASUMS256"  "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
  ( cd "$TMP" && grep " $TARBALL\$" SHASUMS256 | sha256sum -c - )
  mkdir -p "$OPT/node"
  tar -xJf "$TMP/$TARBALL" -C "$OPT/node" --strip-components=1
  rm -rf "$TMP"
  NODE_DIR="$OPT/node"
  export PATH="$NODE_DIR/bin:$PATH"
fi

# ------------------------------------------------------------ claude code ---

# Claude Code is one native binary that updates itself in place — but only
# somewhere it can write. Installing it through npm, as this Feature used to,
# left a root-owned copy under /opt that its updater could not touch. Claude
# Code's own advice at that point is `claude install`, which quietly drops a
# *second* copy under the user's home; from then on there are two versions
# and PATH decides which one runs. So: the official native installer, run as
# the workspace user, into that user's home, once. See docs/adr/0023.
install_claude() {
  local tmp launcher
  log "installing Claude Code (native installer) for $REMOTE_USER"
  tmp="$(mktemp -d)"
  chmod 0755 "$tmp"
  curl -fsSL -o "$tmp/install.sh" https://claude.ai/install.sh

  # The installer records how Claude Code was installed in its config
  # directory. At build time that must not be the state volume — it is not
  # mounted yet, and containerEnv already points CLAUDE_CONFIG_DIR at it — so
  # it gets a scratch one here, and `agentified start` seeds the real one.
  install -d -m 0700 -o "$REMOTE_USER" "$tmp/config"
  as_remote_user env -i \
    HOME="$REMOTE_USER_HOME" USER="$REMOTE_USER" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CLAUDE_CONFIG_DIR="$tmp/config" \
    bash "$tmp/install.sh"
  rm -rf "$tmp"

  # The installer stages its download under ~/.claude. That is not the config
  # directory here and must not be left around looking like one.
  rm -rf "$REMOTE_USER_HOME/.claude/downloads"
  rmdir "$REMOTE_USER_HOME/.claude" 2>/dev/null || true

  launcher="$REMOTE_USER_HOME/.local/bin/claude"
  [ -L "$launcher" ] || { echo "agentified: the native installer did not create $launcher" >&2; exit 1; }
  as_remote_user "$launcher" --version >/dev/null

  # One `claude`, reachable from any PATH. /usr/local/bin holds a link to the
  # launcher the updater manages, not a copy of its own: after an update both
  # names still resolve to the same, new, binary.
  ln -sfn "$launcher" /usr/local/bin/claude
}

# --------------------------------------------------------------------- pi ---

NPM_PREFIX="$OPT/npm"

# Install with --ignore-scripts so no *transitive* dependency gets to run
# arbitrary code during our build, then run the postinstall of the one
# top-level package we asked for, deliberately and by name.
#
# A package whose postinstall does real work is otherwise present but broken:
# Claude Code, when it was still installed this way, fetched its native binary
# in postinstall and failed with "native binary not installed" without it.
# Blanket --ignore-scripts, as the original recipe prescribed, produces a
# container where the agent is present but cannot start. See docs/adr/0013.
install_agent() {
  local pkg="$1"
  log "installing $pkg"
  npm install -g --prefix "$NPM_PREFIX" --ignore-scripts --no-fund --no-audit "$pkg"

  local dir="$NPM_PREFIX/lib/node_modules/$pkg" script
  [ -d "$dir" ] || { echo "agentified: $pkg did not install to $dir" >&2; exit 1; }
  script="$(node -p "try{require('$dir/package.json').scripts.postinstall||''}catch(e){''}")"
  if [ -n "$script" ]; then
    log "running $pkg postinstall (top-level package only)"
    ( cd "$dir" && PATH="$NPM_PREFIX/bin:$PATH" sh -c "$script" )
  fi
}

# Agent CLIs have `#!/usr/bin/env node` shebangs. If we installed a private
# Node, that shebang would resolve to whatever node is on the *user's* PATH —
# or to nothing at all. Wrapping is what keeps the two toolchains apart.
wrap_agent_bin() {
  local name="$1" target="$2" extra=""

  # Pi has no managed-settings equivalent, but it does accept
  # --append-system-prompt with a file path, and the flag is repeatable — so a
  # user passing their own still composes. This is the only hook it offers.
  if [ "$name" = "pi" ] && [ "$AGENT_POLICY" != "off" ]; then
    extra="--append-system-prompt \"$SHARE/policy/agent-notes.md\""
  fi

  cat > "/usr/local/bin/$name" <<EOF
#!/bin/sh
# Generated by agentified: pins the agent to its own Node runtime.
${NODE_DIR:+PATH="$NODE_DIR/bin:\$PATH"; export PATH}
exec "$target" $extra "\$@"
EOF
  chmod 0755 "/usr/local/bin/$name"
}

if wants pi; then
  mkdir -p "$NPM_PREFIX"
  install_agent "@earendil-works/pi-coding-agent"
  for b in "$NPM_PREFIX"/bin/*; do
    [ -e "$b" ] || continue
    wrap_agent_bin "$(basename "$b")" "$b"
  done
fi

if wants claude; then
  install_claude
fi

# ------------------------------------------------------------- proxy user ---

if ! id -u agentproxy >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin agentproxy
fi
mkdir -p /var/log/agentified /run/agentified "$ETC"
chown agentproxy:agentproxy /var/log/agentified /run/agentified

# ---------------------------------------------------------- runtime files ---

log "installing runtime files into $SHARE"
rm -rf "$SHARE"
mkdir -p "$SHARE"
cp -r "$SRC/files/profiles" "$SHARE/profiles"
cp -r "$SRC/files/lib"      "$SHARE/lib"
cp -r "$SRC/files/policy"   "$SHARE/policy"
chmod 0755 "$SHARE/lib/verify.sh"
install -m 0755 "$SRC/files/bin/agentified" /usr/local/bin/agentified
chown -R root:root "$SHARE" /usr/local/bin/agentified
chmod -R go-w "$SHARE"

# ------------------------------------------------------- validate options ---

# Fail the *build* on a typo in `profiles` or `allow`, rather than the first
# agent session. A silently narrower allowlist is the worst failure mode here.
log "validating options"
# shellcheck source=files/lib/common.sh
. "$SHARE/lib/common.sh"
# shellcheck source=files/lib/allowlist.sh
. "$SHARE/lib/allowlist.sh"
# shellcheck source=files/lib/firewall.sh
. "$SHARE/lib/firewall.sh"
# shellcheck source=files/lib/proxy.sh
. "$SHARE/lib/proxy.sh"

case "$MODE" in enforce|learn|off) ;; *) echo "agentified: invalid mode '$MODE'" >&2; exit 1 ;; esac
case "$AGENT_POLICY" in strict|notes-only|off) ;; *) echo "agentified: invalid agentPolicy '$AGENT_POLICY'" >&2; exit 1 ;; esac
case "$DNS_MODE" in resolver-only|blocked|open) ;; *) echo "agentified: invalid dnsMode '$DNS_MODE'" >&2; exit 1 ;; esac
ag_valid_port "$PROXY_PORT" || { echo "agentified: invalid proxyPort '$PROXY_PORT'" >&2; exit 1; }

# containerEnv advertises 3128 and cannot be told otherwise: a Feature option
# cannot be substituted into it (docs/adr/0024). On any other port, shells read
# the real one from profile.d and everything else — an editor server, the
# language servers it spawns — gets an address nothing is listening on.
if [ "$PROXY_PORT" != "3128" ]; then
  P="http://127.0.0.1:${PROXY_PORT}"
  printf '\n[agentified/install] WARNING: proxyPort is %s, but containerEnv advertises 3128.\n' "$PROXY_PORT" >&2
  printf '[agentified/install]   Shells get %s; anything that does not read profile.d gets 3128.\n' "$PROXY_PORT" >&2
  printf '[agentified/install]   Add this to your devcontainer.json (it merges after the Feature, so it wins):\n' >&2
  printf '[agentified/install]     "containerEnv": {\n' >&2
  printf '[agentified/install]       "http_proxy": "%s", "https_proxy": "%s",\n' "$P" "$P" >&2
  printf '[agentified/install]       "HTTP_PROXY": "%s", "HTTPS_PROXY": "%s"\n' "$P" "$P" >&2
  printf '[agentified/install]     }\n\n' >&2
  unset P
fi
ag_compile_allowlist "$SHARE/profiles" "$PROFILES" "$ALLOW" > /dev/null
ag_render_ipv4 0 "$DNS_MODE" "" "$EXTRA_CIDRS" > /dev/null

# Installing an agent without its profile gives you an agent that starts and
# then cannot reach its own API — a failure that looks like the agent is broken
# rather than like a policy decision. Warn loudly at build time; `verify` turns
# the same condition into a named failure.
for agent in claude pi; do
  case ",$AGENTS," in
    *",$agent,"*)
      case ",$PROFILES," in
        *",$agent,"*) ;;
        *) printf '\n[agentified/install] WARNING: agents includes "%s" but profiles does not.\n' "$agent" >&2
           printf '[agentified/install]   %s will start and then fail to reach its own API.\n' "$agent" >&2
           printf '[agentified/install]   Add "%s" to profiles, or list its hosts in allow.\n\n' "$agent" >&2 ;;
      esac ;;
  esac
done

# ----------------------------------------------------------- agent policy ---

# The observed failure mode is an agent helpfully dismantling the boundary
# because it looks like a fault (docs/adr/0018). Two layers answer that:
#
#   notes  — tell the agent the boundary is deliberate and give it a better
#            move than routing around it. Advisory: an injected instruction
#            overrides it as easily as anything else.
#   deny   — refuse the tool calls outright through Claude Code's managed
#            settings, which no user, project or local settings file can
#            override. Mechanical rather than advisory: the agent does not get
#            to reason past it in the moment.
#
# Neither makes this a sandbox. See docs/adr/0019.
if [ "$AGENT_POLICY" = "strict" ]; then
  case ",$AGENTS," in
    *,claude,*)
      log "installing Claude Code managed settings (deny sudo and firewall tools)"
      mkdir -p /etc/claude-code
      install -m 0644 -o root -g root \
        "$SRC/files/policy/claude-managed-settings.json" \
        /etc/claude-code/managed-settings.json
      ;;
  esac
fi

# ----------------------------------------------------------------- config ---

cat > "$ETC/config" <<EOF
# Generated by the agentified Feature at build time. Root-owned by design:
# the workspace user must not be able to widen its own allowlist by editing it.
AGENTS=${AGENTS}
AGENT_POLICY=${AGENT_POLICY}
PROFILES=${PROFILES}
ALLOW=${ALLOW}
EXTRA_CIDRS=${EXTRA_CIDRS}
DNS_MODE=${DNS_MODE}
MODE=${MODE}
PROXY_PORT=${PROXY_PORT}
ALLOW_IPV6=${ALLOW_IPV6}
REMOTE_USER=${REMOTE_USER}
REMOTE_USER_HOME=${REMOTE_USER_HOME}
EOF
chown root:root "$ETC/config"
chmod 0644 "$ETC/config"

# ------------------------------------------------------------ proxy env ----

# The proxy variables are in the Feature's containerEnv, which reaches every
# process in the container (docs/adr/0024). They are written here as well, for
# the two jobs containerEnv cannot do:
#
#   - containerEnv cannot interpolate a Feature option, so it hardcodes 3128.
#     This file carries the port actually configured.
#   - containerEnv does not survive anything that resets the environment —
#     su -l, cron, sudo -i. profile.d does, exactly as for CLAUDE_CONFIG_DIR.
#
# The bashrc and zshenv hooks cover shells that do not read profile.d.
ENVFILE=/etc/profile.d/90-agentified.sh
cat > "$ENVFILE" <<EOF
# Generated by agentified.
export http_proxy="http://127.0.0.1:${PROXY_PORT}"
export https_proxy="http://127.0.0.1:${PROXY_PORT}"
export HTTP_PROXY="http://127.0.0.1:${PROXY_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${PROXY_PORT}"
export NO_PROXY="localhost,127.0.0.1,::1,.local,.internal"
export no_proxy="\$NO_PROXY"
EOF

# CLAUDE_CONFIG_DIR is in containerEnv too, and that is what real clients see —
# but anything that resets the environment (su -l, cron, sudo -i) loses it and
# Claude Code silently falls back to ~/.claude, off the state volume and gone at
# the next rebuild. profile.d survives the reset, for the same reason the proxy
# variables are written here as well (docs/adr/0024).
case ",$AGENTS," in
  *,claude,*)
    cat >> "$ENVFILE" <<EOF
export CLAUDE_CONFIG_DIR="${STATE}/claude"
EOF
    ;;
esac

# The variables above point at a proxy that exists only while agentified is
# running — and a boundary that never started, or that is running in learn
# mode, exports exactly the same ones. Nothing else the user sees distinguishes
# those from an enforcing container, so a new shell says which it is.
#
# The wording lives in the CLI so `status` and this cannot drift apart. Here:
# interactive shells only, and its stdout goes to stderr, because this file is
# also sourced from /etc/zsh/zshenv — which every zsh script reads, and where
# stdout belongs to scp and rsync. The redirections are ordered so that the
# message reaches the terminal while the command's own errors are dropped.
if [ "$MODE" != "off" ]; then
  cat >> "$ENVFILE" <<EOF

case "\$-" in
  *i*)
    if [ -z "\${AGENTIFIED_NO_WARN:-}" ] && command -v agentified >/dev/null 2>&1; then
      agentified shell-warning >&2 2>/dev/null || true
    fi
    ;;
esac
EOF
fi
chmod 0644 "$ENVFILE"

HOOK=". $ENVFILE  # agentified"
for rc in /etc/bash.bashrc /etc/zsh/zshenv; do
  [ -f "$rc" ] || continue
  grep -qF "# agentified" "$rc" || printf '\n%s\n' "$HOOK" >> "$rc"
done

# --------------------------------------------------------------- sudoers ----

# Sudoers matches the full argument vector, so every invocation the lifecycle
# hooks make has to be spelled out. A bare `agentified start` entry would NOT
# authorise `agentified start --proxy-only`.
cat > /etc/sudoers.d/agentified <<EOF
${REMOTE_USER} ALL=(root) NOPASSWD: \\
  /usr/local/bin/agentified start, \\
  /usr/local/bin/agentified start --proxy-only, \\
  /usr/local/bin/agentified stop, \\
  /usr/local/bin/agentified status, \\
  /usr/local/bin/agentified preflight, \\
  /usr/local/bin/agentified verify, \\
  /usr/local/bin/agentified hosts, \\
  /usr/local/bin/agentified learn, \\
  /usr/local/bin/agentified denied, \\
  /usr/local/bin/agentified logs, \\
  /usr/local/bin/agentified logs *
EOF
chmod 0440 /etc/sudoers.d/agentified
visudo -cf /etc/sudoers.d/agentified

log "done. mode=$MODE profiles=$PROFILES agents=$AGENTS user=$REMOTE_USER"
