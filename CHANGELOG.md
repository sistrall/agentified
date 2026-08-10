# Changelog

Published as `ghcr.io/sistrall/agentified/agentified`. Each release gets four
tags — `0.2.0`, `0.2`, `0` and `latest` — so `:0` follows the newest 0.x and
`:0.2` stays on the 0.2 line.

While this is 0.x, a minor bump may change behaviour. Read the entry before
moving `:0`.

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
