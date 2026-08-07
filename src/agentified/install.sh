#!/usr/bin/env bash
# agentified :: build-time installer. Runs as root during image build.
#
# Feature options arrive as uppercased environment variables (AGENTS, PROFILES,
# ALLOW, ...). _REMOTE_USER and _REMOTE_USER_HOME are supplied by the Features
# tooling and are needed here because the runtime script has to know whose home
# directory to link state into.
#
# NOTE: this script runs *before* any of the egress rules exist and needs the
# apt mirrors, nodejs.org and registry.npmjs.org. "Add the Feature and rebuild"
# assumes unrestricted egress at build time. See README §Limitations.
set -euo pipefail

# If anything upstream exported proxy variables into the build (a corporate
# base image, or a user who added them to containerEnv by hand), they point at
# a proxy that does not exist yet. Our own build must not inherit them.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY

AGENTS="${AGENTS:-claude}"
AGENT_POLICY="${AGENTPOLICY:-strict}"
PROFILES="${PROFILES:-base,editor}"
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
NODE_VERSION=22.20.0

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n[agentified/install] %s\n' "$*"; }

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

need_node() {
  local bin major
  bin="$(command -v node || true)"
  [ -n "$bin" ] || return 0
  major="$("$bin" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "$major" -ge 22 ] && return 1
  return 0
}

NODE_DIR=""
if [ "$AGENTS" != "none" ] && need_node; then
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

# ----------------------------------------------------------------- agents ---

NPM_PREFIX="$OPT/npm"

# Install with --ignore-scripts so no *transitive* dependency gets to run
# arbitrary code during our build, then run the postinstall of the one
# top-level package we asked for, deliberately and by name.
#
# Claude Code needs this: its postinstall fetches the platform-native binary,
# and without it `claude --version` fails with "native binary not installed".
# Blanket --ignore-scripts, as the original recipe prescribed, produces a
# container where the agent is present but cannot start.
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

if [ "$AGENTS" != "none" ]; then
  mkdir -p "$NPM_PREFIX"
  case ",$AGENTS," in *,claude,*) install_agent "@anthropic-ai/claude-code" ;; esac
  case ",$AGENTS," in *,pi,*)     install_agent "@earendil-works/pi-coding-agent" ;; esac

  if [ -d "$NPM_PREFIX/bin" ]; then
    for b in "$NPM_PREFIX"/bin/*; do
      [ -e "$b" ] || continue
      wrap_agent_bin "$(basename "$b")" "$b"
    done
  fi
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

# The proxy variables live here rather than in the Feature's containerEnv,
# because containerEnv is baked into the image as ENV *above* the install
# layers — it would point build-time apt/curl/npm at a port that only exists at
# runtime, breaking this Feature's own build and every Feature ordered after it.
#
# At runtime the devcontainer tooling probes a login+interactive shell
# (userEnvProbe, default loginInteractiveShell) and applies the result to
# lifecycle commands, terminals and the editor server — so profile.d reaches
# everything containerEnv would have, minus the build-time damage. The bashrc
# and zshenv hooks cover users who set userEnvProbe to a non-login mode.
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
