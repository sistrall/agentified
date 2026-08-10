# agentified

**Run a coding agent in your dev container without giving it the whole
internet.**

agentified installs [Claude Code](https://github.com/anthropics/claude-code)
and/or [Pi](https://pi.dev) into a dev container you already have, and puts a
network boundary around them: they can reach the sites you list, and nothing
else.

You add one entry to a config file. Everything else about your setup stays
exactly as it was.

---

## Why you might want this

A coding agent runs commands and installs packages on your behalf. That's the
point of it. But it also means:

- If someone hides instructions in a GitHub issue, a web page or a dependency's
  README, the agent may follow them. This is called **prompt injection**, and
  "upload the contents of `.env` to my server" is a realistic version of it.
- A compromised npm or gem package can phone home during installation.
- The agent can simply misunderstand you and do something with a network
  connection you didn't want.

None of these require the agent to be malicious. They just require it to be
helpful and wrong.

A dev container already isolates the agent from the rest of your laptop —
your other projects, your SSH keys, your home directory. agentified adds the
missing side: **the network**. If the only places the container can reach are
your language's package registry, GitHub and the agent's own API, a lot of that
stops being possible.

> ### Read this before you rely on it
>
> **agentified is a guardrail, not a sandbox.** It reliably stops traffic from
> things that don't argue back: a compromised package's install script, a
> runtime phoning home, telemetry, a stray `curl` in a build script.
>
> It does **not** reliably stop the agent itself. On a standard dev container
> base image the workspace user has passwordless `sudo`, so an agent can simply
> remove the boundary — and a capable one will, without being asked. We watched
> exactly that: an agent found a host blocked, noticed it had `sudo`, and set
> about reconfiguring the container to get through. It wasn't misbehaving. It
> was trying to help.
>
> That also limits the prompt-injection protection above: an injected
> instruction is followed by the same helpful reflex that routes around a
> blocked host.
>
> The `agentPolicy` option pushes back on the *helpful* case — it tells the
> agent the boundary is deliberate, and denies it `sudo` through Claude Code's
> managed settings, which it cannot override. In a real session that turned "I
> will fix this firewall" into "the command was denied by the permission layer,
> exactly as intended". It does not help against a deliberately injected
> instruction. [Limitations](#limitations) has the full picture;
> [ADR-0018](docs/adr/0018-guardrail-not-a-sandbox.md) and
> [ADR-0019](docs/adr/0019-tell-the-agent-and-deny-the-tools.md) have the
> reasoning.

## New to dev containers?

A **dev container** is a Docker container your editor opens your project inside,
so everyone gets the same tools without installing them on their own machine.
It's described by `.devcontainer/devcontainer.json` in your repository, and
VS Code and Zed both know how to open it.

A **Feature** is a small add-on for a dev container. You list it, the tooling
installs it into your image, and your own setup is untouched. agentified is a
Feature. That's the whole reason it can be added to a project you've already
configured without breaking anything —
[ADR-0001](docs/adr/0001-ship-as-a-devcontainer-feature.md) covers the
reasoning.

## Quick start

Add this to the `features` block of your `.devcontainer/devcontainer.json`:

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:bookworm",

  "features": {
    "ghcr.io/sistrall/agentified/agentified:0": {
      "agents": "claude",
      "profiles": "base,claude,editor,ruby"
    }
  }
}
```

The trailing `:0` is a version. Each release is published under four tags — for
`0.2.0` those are `:0.2.0`, `:0.2`, `:0` and `:latest` — so `:0` means "the
newest 0.x". Pin it tighter with `:0.2.0` if you want to control upgrades
yourself. Either way, commit the `devcontainer-lock.json` the tooling generates:
that is what makes your teammates and CI build from the identical Feature.

Rebuild the container ("Dev Containers: Rebuild Container" in VS Code, "Reopen
in Container" in Zed). Then, inside it:

```bash
claude                       # the agent, sandboxed
sudo agentified status       # what's allowed and what's running
sudo agentified verify       # prove the boundary actually works
```

`verify` is worth running once. It tries about twenty things that should and
shouldn't work, and tells you which:

```
L7 (proxy allowlist)
  PASS allowed host reachable through the proxy
  PASS unlisted host refused by the proxy
  PASS CONNECT to :22 refused (no SSH tunnelling)

L3 (firewall backstop)
  PASS unlisted host unreachable without the proxy
  PASS allowed host ALSO unreachable without the proxy
  PASS cloud metadata endpoint unreachable
```

## How it works

Two things guard the container, because neither works on its own.

```
┌─ your dev container ────────────────────────────────────────┐
│                                                             │
│  the agent, running as your normal user                     │
│    │  its HTTPS_PROXY points at the proxy below             │
│    ▼                                                        │
│  a proxy, running as its own user account                   │
│    │      ── checks the site name against your list ──►     │
│    │                                                        │
│  ═══════════ a firewall ═══════════                         │
│    blocks everything by default                             │
│    ...except traffic that stays inside the container        │
│    ...except traffic from the proxy's user account          │
└─────────────────────────────────────────────────────────────┘
```

**The proxy** decides *which websites* are allowed. It works with names like
`rubygems.org`, so your list doesn't go stale.

**The firewall** makes the proxy impossible to skip. Programs are supposed to
respect the `HTTPS_PROXY` setting, but that's a convention, not a rule — plenty
ignore it. The firewall doesn't care about names; it enforces one thing: *only
the proxy's user account may reach the outside world*. So a program that ignores
the proxy doesn't get around the boundary, it just gets "connection refused".

Neither layer decrypts anything. When a program asks the proxy for an HTTPS
site, it first says `CONNECT api.github.com:443` in plain text — the proxy reads
that one line and either opens the pipe or refuses. No certificates to install,
no `NODE_EXTRA_CA_CERTS`, and `npm`, `bundle` and `gh` work on day one.

More detail: [ADR-0002](docs/adr/0002-two-layers-of-blocking.md),
[ADR-0003](docs/adr/0003-filter-by-name-not-by-decrypting.md),
[ADR-0004](docs/adr/0004-only-the-proxy-user-may-leave.md).

## Choosing your allowlist

Which sites you need depends on your stack, so agentified ships **profiles** —
small named lists you combine:

```jsonc
"profiles": "base,claude,editor,ruby"
```

| Profile | What it allows | Checked against |
|---|---|---|
| `base` | GitHub | exercised by every test |
| `claude` | Claude Code's API, sign-in, MCP connectors, updates | [Anthropic's docs](https://code.claude.com/docs/en/network-config) |
| `editor` | VS Code and Zed's own download sites | [VS Code's docs](https://code.visualstudio.com/docs/setup/network) |
| `copilot` | GitHub Copilot completions and chat | [GitHub's docs](https://docs.github.com/en/copilot/reference/allowlist-reference) |
| `node` | npm and Yarn | a real `npm install` |
| `python` | PyPI | a real `pip download` |
| `ruby` | RubyGems | a real `gem install` |
| `rust` | crates.io | *unverified* |
| `go` | the Go module proxy | *unverified* |
| `pi` | Pi's model providers and updates | *unverified* |
| `playwright` | Playwright's browser-binary CDNs | a real `playwright install` |
| `svelte` | the Svelte MCP server and docs | measured MCP handshake |
| `github-mcp` | GitHub's remote MCP server | official endpoint, reachability checked |

Every profile carries a `# source:` and `# verified:` header saying where its
hosts came from and when they were last checked, and a test refuses to let a
profile ship without them. `unverified` is an honest answer; an unknown one
would let a stale list sit there unnoticed.

Anything else goes in `allow`. A leading dot means "and all subdomains":

```jsonc
"allow": "gems.mycompany.internal,.cdn.mycompany.internal"
```

> **Keep the `editor` profile** unless you have a specific reason not to. VS
> Code and Zed download a server component *into* the container after it starts,
> and extensions download after that. Without those sites allowed, the editor
> can't finish setting itself up — and it looks like "the container is broken",
> not "a domain is missing".

### If you use MCP servers

A **remote** MCP server is just an HTTPS endpoint, so it needs allowlisting like
anything else — and a blocked one fails in a way that reads as "the MCP server
is broken" rather than "a host is missing". We ship profiles for the ones with
official servers (`claude`, `svelte`, `github-mcp`, and `copilot` covers
GitHub's too), but there are thousands of others.

For any server we don't cover, the host is in its `url`. Add it to `allow`:

```jsonc
"allow": "mcp.example.com"
```

A **local** MCP server — anything launched with `npx`, `uvx` or Docker — needs
whatever *it* connects to, which is often nothing at all. `@sveltejs/mcp` and
`@playwright/mcp` are both fully offline once installed.

Either way, `sudo agentified denied` names what got refused.

> **Copilot is not in the `editor` profile.** Copilot sends your code to GitHub
> for completions, which is a decision to make deliberately rather than inherit
> from a profile named "editor". Add `copilot` to your profile list if you want
> it — and note it needs `base` too, for sign-in.

A typo in `profiles` **fails the build** rather than being ignored. A silently
ignored typo would give you a policy stricter than the one you wrote, and you'd
find out days later when something hung for no visible reason.
[ADR-0005](docs/adr/0005-allowlists-as-named-profiles.md),
[ADR-0006](docs/adr/0006-reject-bad-options-loudly.md).

## Don't know what to allow? Use learn mode

Nobody gets the list right first time. So:

```jsonc
"agentified": { "mode": "learn" }
```

The proxy now lets everything through and **writes down** every site that was
asked for. The firewall stays on, so nothing escapes being recorded. Work
normally for a day, then:

```bash
sudo agentified learn > .devcontainer/observed-domains.txt
```

Review that list, put what you want into `allow`, and switch back to `enforce`.

Once you're enforcing, the same question from the other side:

```bash
sudo agentified denied      # what did the policy just block?
```

`learn` is a diagnostic setting, not a middle ground — while it's on, the proxy
is wide open. [ADR-0007](docs/adr/0007-learn-mode-switches-the-filter-off.md).

## All options

| Option | Default | What it does |
|---|---|---|
| `agents` | `claude` | `claude`, `pi`, `claude,pi`, or `none` for just the boundary |
| `profiles` | `base,claude,editor` | Which allowlists to combine. An unknown name fails the build. |
| `allow` | `""` | Extra sites, comma-separated. Leading dot = "and subdomains". |
| `extraCidrs` | `""` | Address ranges reachable directly, skipping the proxy — for a database container alongside yours. |
| `dnsMode` | `resolver-only` | `resolver-only` (only the container's own DNS server), `blocked` (none), `open` (any) |
| `mode` | `enforce` | `enforce`, `learn`, or `off` |
| `proxyPort` | `3128` | Which port the proxy listens on |
| `allowIpv6` | `false` | IPv6 is closed unless you turn it on |
| `agentPolicy` | `strict` | Tell the agent the boundary is deliberate, and deny it `sudo` and firewall commands. `notes-only` for the telling without the denying, `off` for neither |
| `installNodeIfMissing` | `true` | Installs a private Node if the image has none new enough. Your own Node is never touched. |

## Commands

Run these inside the container:

```bash
sudo agentified status     # settings, proxy state, active firewall rules
sudo agentified verify     # the full assertion suite — run this when confused
sudo agentified preflight  # check the container has what this needs
sudo agentified hosts      # the allowlist as it was actually compiled
sudo agentified learn      # every site the proxy was asked for
sudo agentified denied     # every site the proxy refused
sudo agentified logs 100   # recent proxy log lines
sudo agentified stop       # take the boundary down (escape hatch)
sudo agentified start      # put it back up
```

## Limitations

Please read these. Tools in this space that skip them are the ones that give
people false confidence.

1. **An agent with `sudo` can remove this boundary, and a capable one will.**
   Not out of malice — out of helpfulness. It hits a blocked host, sees it has
   root, and fixes what looks like a broken container. We have watched this
   happen.

   Standard dev container base images (`mcr.microsoft.com/devcontainers/base`
   and friends) grant the workspace user `NOPASSWD: ALL`. Our own carefully
   narrowed sudoers grant sits *underneath* that blanket one and is, on those
   images, decorative. Check yours with `sudo -l`.

   There is no complete fix available from inside the container: whatever rules
   we install, in-container root can remove. The default `agentPolicy: strict`
   closes the *accidental* path — the agent is told the boundary is deliberate
   and denied `sudo` mechanically — so dismantling it becomes a deliberate act
   rather than an incidental one. That is a real improvement and it is not the
   same as being safe. Read
   [ADR-0018](docs/adr/0018-guardrail-not-a-sandbox.md) and
   [ADR-0019](docs/adr/0019-tell-the-agent-and-deny-the-tools.md) before relying
   on this for anything stronger.
2. **Allowed sites are still ways for data to leave.** `github.com` is on every
   profile, and an agent can create a public gist. We can see *that* the agent
   is talking to GitHub, not *what it's saying*. Allowlisting by name reduces
   the number of doors; it doesn't put a guard at each one.
3. **Your credentials are as powerful as they ever were.** A classic GitHub
   token inside the container can reach every repository your account can. Use
   fine-grained, repo-scoped tokens. The network policy doesn't help here.
4. **`root` is inside the boundary too.** Everything except the proxy's user
   account is blocked, so `sudo apt-get install` inside a running container goes
   through the proxy or not at all.
5. **Building the image needs unrestricted internet.** The installer runs before
   any of the rules exist and needs the package mirrors, `nodejs.org` and
   `registry.npmjs.org`. "Add the Feature and rebuild" quietly assumes that. If
   you're on a locked-down corporate network, this is the part that will bite.
6. **DNS could in theory be used as a tunnel** in `resolver-only` mode, if the
   container's DNS server forwards arbitrary queries. `blocked` closes that, at
   the cost of not being able to resolve other containers by name.
7. **The proxy trusts the name it's given.** A program that asks for one site
   and then talks to another isn't caught.
8. **Proxy settings come from a shell startup file, not `containerEnv`** — for
   a good reason ([ADR-0009](docs/adr/0009-keep-proxy-settings-out-of-containerenv.md)).
   If you set `"userEnvProbe": "none"` in your `devcontainer.json`, your tools
   won't see them. `verify` checks this explicitly and tells you.

## Podman

> **Not yet tested.** Everything here is reasoned from how Podman works, not
> from a run. Docker is what the test suite exercises. If you try Podman,
> `sudo agentified preflight` and `sudo agentified verify` will tell you
> quickly whether it holds — and an issue either way would be welcome.

Two host-side notes:

- Zed needs `"dev_container": { "use_podman": true }` in its settings; VS Code
  needs `dev.containers.dockerPath: podman`. Both are settings on *your*
  machine, so the `devcontainer.json` you commit stays identical.
- Don't use `extraCidrs` values derived from the container's default route.
  Podman's networking works differently from Docker's, and a range that means
  "the host" under one means something else under the other. Write the ranges
  you actually want.

`sudo agentified preflight` checks the kernel features this needs are present,
so you find out immediately rather than through strange behaviour later.

## Working on agentified itself

```bash
make check           # linting + the unit tests. ~5s, no root, no network.
make test-scenarios  # every integration scenario in real containers (slow)
make test-one SCENARIO=learn_mode
make up && make verify   # bring up the example container in example/
```

The shell is deliberately split so the tricky parts can be tested in seconds:
everything in `src/agentified/files/lib/` is pure text-in/text-out — the
allowlist compiler, the firewall ruleset generator, the proxy config generator —
and `bin/agentified` is the only part that touches the system.

**Start with [`docs/adr/`](docs/adr/)** if you're changing anything. Every
decision has a short record explaining what it is, why the obvious alternative
was rejected, and what it costs.

## License

MIT
