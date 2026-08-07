# Architecture Decision Records

Every meaningful choice in this project gets a short document explaining what we
decided and, more importantly, **why**. That way nobody has to guess later, and
if you disagree with something you can see exactly what trade-off was made.

Each record follows the same shape: the problem, the decision, why we didn't do
the obvious alternative, what it costs us, and how it's tested.

You do not need to read these in order, and you don't need to read them at all
to *use* agentified — start with the [README](../../README.md) for that. These
are for people changing the code, or wondering "why on earth is it done like
that?"

## The records

### The big shape of the thing

| # | Decision |
|---|---|
| [0001](0001-ship-as-a-devcontainer-feature.md) | Ship this as a Dev Container Feature, not a ready-made image |
| [0002](0002-two-layers-of-blocking.md) | Use two layers of blocking, not one |
| [0003](0003-filter-by-name-not-by-decrypting.md) | Filter by website name; don't decrypt the agent's HTTPS traffic |
| [0004](0004-only-the-proxy-user-may-leave.md) | Let only the proxy's user account reach the internet |
| [0018](0018-guardrail-not-a-sandbox.md) | **This is a guardrail, not a sandbox — and the docs must say so first** |
| [0019](0019-tell-the-agent-and-deny-the-tools.md) | Tell the agent the boundary is deliberate, and deny it the tools anyway |

### How the allowlist works

| # | Decision |
|---|---|
| [0005](0005-allowlists-as-named-profiles.md) | Ship allowlists as named profiles you mix and match |
| [0006](0006-reject-bad-options-loudly.md) | Reject bad option values instead of quietly ignoring them |
| [0007](0007-learn-mode-switches-the-filter-off.md) | Learn mode switches the filter off; it does not invert it |
| [0017](0017-do-not-auto-include-agent-profiles.md) | Warn when an agent has no profile, but don't add it automatically |

### Getting it running inside the container

| # | Decision |
|---|---|
| [0008](0008-proxy-early-firewall-late.md) | Start the proxy early, switch the firewall on late |
| [0009](0009-keep-proxy-settings-out-of-containerenv.md) | Don't put proxy settings in `containerEnv` |
| [0010](0010-write-firewall-rules-as-text.md) | Write the firewall rules as text, then load them in one go |
| [0011](0011-spell-out-every-allowed-sudo-command.md) | Spell out every command the user is allowed to `sudo` |
| [0012](0012-block-cloud-metadata-address.md) | Block the cloud metadata address, even for the proxy |

### Installing the agents

| # | Decision |
|---|---|
| [0013](0013-run-only-the-agents-own-install-script.md) | Run only the agent's own install script, not its dependencies' |
| [0014](0014-private-node-with-wrapper-commands.md) | Give the agents their own Node, and wrap their commands |
| [0015](0015-agent-logins-in-a-per-project-volume.md) | Keep agent logins in a per-project volume |

### How we test it

| # | Decision |
|---|---|
| [0016](0016-test-in-two-layers.md) | Test in two layers: fast checks and real containers |

## Things we haven't decided yet

Open questions, written down so they don't get forgotten:

- **Should we offer a mode that inspects requests, not just website names?**
  Right now we can allow `github.com` or block it, but we can't tell the
  difference between "reading a repository" and "publishing a secret to a public
  gist". A tool called mitmproxy could do that, at the cost of installing a
  certificate into the container and breaking some tools. See
  [ADR-0003](0003-filter-by-name-not-by-decrypting.md).
- **What about multi-container setups?** If your project uses Docker Compose
  with a separate database container, the `extraCidrs` option is meant to let
  the agent reach it. The option is tested, but we have never actually stood up
  a real database container alongside and checked.
- **Does this survive a real editor rebuild?** Our automated tests use the
  headless command line. Nobody has scripted "click Rebuild Container in VS
  Code" or Zed's "Reopen in Container".
- **Do agent logins really survive a rebuild?** We check that the storage volume
  exists and is writable, but no test actually logs into Claude Code, rebuilds,
  and confirms you're still logged in. See
  [ADR-0015](0015-agent-logins-in-a-per-project-volume.md).
- **Could we shrink the `editor` allowlist?** If we pre-installed the editor's
  server component when the image is built, we might not need to allow the
  editor's download sites at all afterwards.
