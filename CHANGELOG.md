# Changelog

Published as `ghcr.io/sistrall/agentified/agentified`. Each release gets four
tags — `0.3.0`, `0.3`, `0` and `latest` — so `:0` follows the newest 0.x and
`:0.3` stays on the 0.3 line.

While this is 0.x, a minor bump may change behaviour. Read the entry before
moving `:0`.

## 0.3.0

Three reports of the boundary lying about itself, all fixed. Nothing about the
allowlist or the rules changed; what changed is what agentified tells you about
them. Upgrading from 0.2.0 needs no config change.

**Fixed**

- **`status` reported the configured mode, not the running one.** After
  `sudo AGENTIFIED_MODE=learn agentified start` it kept saying `enforce` at a
  proxy permitting every host. `start` now records what it applied and `status`
  reads that back, annotating the line — `mode : learn   (config: enforce)` —
  when the two disagree. When nothing is running the mode line says so instead
  of naming a mode. `verify` asserts the two agree, by name, so a learn-mode
  proxy no longer fails the enforce assertions as if the allowlist were broken.
  ([#3](https://github.com/sistrall/agentified/issues/3),
  [ADR-0021](docs/adr/0021-report-what-is-running-not-what-was-configured.md))
- **A stopped proxy could report itself as running, forever.** The liveness
  check counted zombie processes, and nothing reaps them when PID 1 is the
  usual `sleep infinity`. Every proxy that had ever exited stayed visible. The
  check now skips zombies.
- **`verify` could not see `CLAUDE_CONFIG_DIR`.** It probes a login shell,
  which resets the environment, and the variable only came from `containerEnv`
  — so it reported `got 'unset'` on containers where the setting was correct.
  It is now exported from `/etc/profile.d` as well, which also makes it true
  for anything started from `su -l`, `cron` or `sudo -i`, where Claude Code
  would otherwise have fallen back to `~/.claude` and off the state volume.
  ([#2](https://github.com/sistrall/agentified/issues/2),
  [ADR-0009](docs/adr/0009-keep-proxy-settings-out-of-containerenv.md))

**Added**

- **A new interactive shell warns when the boundary is not enforcing.** Zed
  does not run a Feature's `onCreateCommand`/`postStartCommand`, and a container
  restarted outside the devcontainer tooling doesn't either — so agentified
  could be fully installed, fully inert, and silent about it, while the proxy
  variables it exported made the symptom look like a broken proxy. The same
  shell hook also names learn mode, and a `--proxy-only` start whose firewall
  half never ran. Output goes to stderr, interactive shells only, and the hook
  is not installed at all when `mode=off`; `AGENTIFIED_NO_WARN=1` silences it.
  ([#1](https://github.com/sistrall/agentified/issues/1),
  [ADR-0022](docs/adr/0022-a-boundary-that-did-not-start-must-say-so.md))
- **`status` names the states that filter nothing** — learn mode, `mode=off`,
  and a proxy started with `--proxy-only` whose firewall half never ran.
- **`agentified running`** — exit status only, no output, no `sudo`. What a
  script should use instead of parsing `status`. `agentified shell-warning` is
  the same idea for a shell startup file, and is what the hook above calls.
- **A Zed entry in the README's Limitations**, with the two lines to copy into
  your own `devcontainer.json` until Zed runs Feature-contributed hooks.

## 0.2.0

New profiles, all measured rather than guessed. Nothing existing changed, so
upgrading from 0.1.0 alters nothing unless you add one of these to `profiles`.

**Added**

- **`playwright`** — `cdn.playwright.dev`,
  `playwright.download.prss.microsoft.com`. Playwright fetches browser binaries
  from its own CDN, so `npm install` succeeds and `playwright install` is what
  fails.
- **`svelte`** — `mcp.svelte.dev`, `svelte.dev`. For the Svelte MCP server. The
  *build* toolchain needs nothing beyond `node`; this profile is for the agent
  side.
- **`github-mcp`** — `api.githubcopilot.com`. GitHub's remote MCP server is
  hosted on a Copilot domain, so without this you would have to enable the whole
  `copilot` profile — and its code-completion traffic — just to use it.
- An **"If you use MCP servers"** section in the README: remote servers are
  ordinary HTTPS endpoints and need allowlisting; local ones usually need
  nothing.

**Known gap**

Automated profile verification covers package managers only. It cannot see MCP
servers, documentation lookups, or anything the agent invokes rather than the
build — which is why the `svelte` profile had to be worked out by hand. Tracked
in the [ADR index](docs/adr/README.md).

## 0.1.0

First release.

- A CONNECT-allowlisting proxy plus an iptables backstop that only the proxy's
  own user may cross, so tools that ignore `HTTPS_PROXY` are stopped rather than
  waved through.
- Installs Claude Code and/or Pi, with logins kept in a per-project volume that
  survives rebuilds.
- Composable allowlist profiles: `base`, `claude`, `pi`, `editor`, `copilot`,
  `node`, `python`, `ruby`, `rust`, `go`.
- `learn` mode, and `agentified denied`, for finding out what your stack
  actually needs.
- `agentPolicy` (default `strict`): tells the agent the boundary is deliberate
  and denies it `sudo` through Claude Code's managed settings.
- `agentified verify`, an assertion suite that ships inside the container.

**Please read the README's opening callout.** This is a guardrail, not a
sandbox: an agent with `sudo` can remove the boundary, and a capable one will
try while attempting to help.
