# 0022. A boundary that did not start must say so

**Status:** Accepted · **Date:** 2026-08-11 · **Found by:**
[issue #1](https://github.com/sistrall/agentified/issues/1)

## The problem

The Feature starts itself through two lifecycle hooks it declares:

```jsonc
"onCreateCommand":  "sudo /usr/local/bin/agentified start --proxy-only",
"postStartCommand": "sudo /usr/local/bin/agentified start"
```

Zed applies a Feature's `capAdd`, `mounts` and `containerEnv` and **ignores its
lifecycle commands**. Everything else arrives — `CAP_NET_ADMIN` is on the
container, `/agent-state` is mounted, `/etc/profile.d/90-agentified.sh` is
there exporting the proxy variables — and nothing ever starts the proxy.

So the container comes up with `https_proxy` pointing at a port nothing listens
on. The first thing you see is the agent blaming the proxy:

```
Failed to connect to api.anthropic.com: ConnectionRefused
A proxy is configured via https_proxy. Check that it allows connections to the host above.
```

which sends you to read the allowlist, where nothing is wrong. Meanwhile the
`OUTPUT` policy is `ACCEPT` and there is no boundary at all.

The same shape arrives by a second route: `restart: unless-stopped`, or any
`docker restart`, brings the container back with no devcontainer tooling in the
loop, so `postStartCommand` does not fire there either.

This is the worst failure mode a guardrail has. Nothing is refused, nothing
warns, and the configuration looks complete.

## What we decided

**Make the off state loud in the two places someone will actually be looking.**

1. **A new interactive shell says it.** The same `/etc/profile.d` file that
   exports the proxy variables now prints a short warning when the running
   boundary is not enforcing what it was configured to — nothing running, learn
   mode, or a firewall half that never ran. It is the honest partner to those
   exports: the file that tells your tools to use a proxy is the file that
   should tell you when there isn't one.

   The wording lives in the CLI, as `agentified shell-warning`, so it cannot
   drift from what `status` says. Learn mode gets a line there too, for the
   same reason it gets one in `status`: it exports exactly the same variables
   as an enforcing container and filters nothing
   ([ADR-0021](0021-report-what-is-running-not-what-was-configured.md)).

2. **`status` says it, in a block rather than a word.** `proxy: DOWN` was
   already true, but it sat in a summary block among lines that all looked
   equally routine. The mode line no longer names a mode when nothing is
   running, and a `NO BOUNDARY IS RUNNING` block explains what that means, why
   the symptom is `ConnectionRefused`, and that some editors never run a
   Feature's lifecycle commands.

3. **`verify` fails on it by name** — "the boundary is running" — rather than
   through a scatter of downstream assertions.

`--proxy-only` is treated as its own state, not as a start. It is a legitimate
half-way point (that is what `onCreateCommand` applies, per
[ADR-0008](0008-proxy-early-firewall-late.md)), and a container left in it has
the L7 half and no backstop. `status` and `verify` both name it.

The warning is skipped when `mode=off`, where no boundary is the configured
state and the warning would be noise. `AGENTIFIED_NO_WARN=1` turns it off.

## Why not start the boundary ourselves?

The tempting fix is to have the shell hook run `sudo agentified start` when it
finds nothing running — then Zed and `docker restart` both self-heal.

We are not doing that. It would make every new terminal capable of silently
reconfiguring the container's firewall, and it would need a passwordless sudo
path invoked automatically rather than deliberately. A guardrail that rearms
itself from inside a user shell is a larger attack surface than the problem it
closes, and it would hide the underlying breakage instead of reporting it.

Rearming on *boot* rather than on lifecycle would close both routes properly,
but there is no init system in a dev container to hang it off. That stays open.

## What it costs

Interactive shells run one extra command at startup — `agentified
shell-warning`, measured at ~13ms, and silent when there is nothing to say. It
is guarded to interactive shells and its output is redirected to stderr,
because the file is also sourced from `/etc/zsh/zshenv`, which every `zsh`
script reads: output on stdout there lands in the middle of `scp` and `rsync`.

Learn mode is now noisy in every new terminal. That is deliberate — it is the
state most easily left on by accident — but it is the one place here where the
warning is a nag rather than a diagnosis. `AGENTIFIED_NO_WARN=1` exists for it.

And a Zed user still has to do something. The README says what:

```jsonc
"onCreateCommand":  "sudo /usr/local/bin/agentified start --proxy-only",
"postStartCommand": "sudo /usr/local/bin/agentified start"
```

Repeating the Feature's own hooks in `devcontainer.json`. Under tooling that
honours both, they then run twice, which is harmless — every subcommand is
idempotent by design.

## How it's tested

`boundary_only` stops the boundary and asserts that `status` says so, that an
interactive shell warns on stderr, that a non-interactive one stays silent, and
that `verify` fails; with the proxy restarted in learn mode it asserts the
terminal says that too. `off_mode` asserts the hook is not installed at all.
