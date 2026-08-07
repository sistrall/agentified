# 0004. Let only the proxy's user account reach the internet

**Status:** Accepted · **Date:** 2026-08-06

## The problem

[ADR-0002](0002-two-layers-of-blocking.md) says the firewall's job is to make
the proxy impossible to skip. But *how*?

The obvious approach is "transparent redirection": catch every outgoing
connection and secretly reroute it into the proxy. This is a well-known
technique and it is genuinely fiddly — you need address translation rules, the
proxy has to be taught to handle redirected traffic differently from traffic
that was politely sent to it, and debugging it when it goes wrong is miserable.

## What we decided

Don't redirect anything. Instead, use the fact that **the proxy runs as its own
user account**.

When the Feature is installed, it creates a system user called `agentproxy` and
runs the proxy as that user. Then the firewall gets one rule that does all the
work:

```
allow outgoing traffic if it was created by the user "agentproxy"
```

...plus "block everything else". That's it.

Linux firewalls can match on which user account created a connection (the option
is called `--uid-owner`). So:

- The agent runs as your normal user → the firewall blocks any direct
  connection it makes.
- The agent connects to the proxy instead → that connection never leaves the
  container, so it's allowed.
- The proxy makes the real outgoing connection → it's running as `agentproxy`,
  so it's allowed.

The agent is *physically unable* to reach the outside world except by asking the
proxy, and the proxy only says yes to sites on the list.

## Why this and not transparent redirection

- **It's one rule instead of a subsystem.** Less to get wrong, less to explain,
  much less to debug.
- **The proxy needs no special mode.** It just sees normal proxy requests.
- **The failure mode is honest.** If something ignores `HTTPS_PROXY`, it gets a
  clear "connection refused" instead of silently being redirected somewhere it
  didn't expect. Silent redirection makes misconfigured tools *look* like they
  work.

## What it costs

- **It needs a kernel module called `xt_owner`.** It's present essentially
  everywhere, including Podman's virtual machines, but it's not guaranteed. So
  `agentified preflight` checks for it explicitly and tells you, instead of
  letting you find out later through weird behaviour.
- **`root` is inside the boundary too.** The rule allows `agentproxy`, not
  "administrators". So `sudo apt-get install` inside a running container goes
  through the proxy or not at all. This is arguably correct — an agent that can
  `sudo` shouldn't get a free way out — but it does surprise people.
- **The agent could, in principle, become `agentproxy`.** It would need `sudo`
  to do it, which it has. See the limitations section of the
  [README](../../README.md): this stops accidents, not a determined attacker.

## How it's tested

- `test/unit/firewall.bats` asserts the generated rules contain
  `--uid-owner <number> -j ACCEPT` and that the default policy is to block.
- The `verify` suite proves it from the other direction: an **allowed** website
  is unreachable when you bypass the proxy. If the firewall were secretly
  name-aware, that check would fail.
- `agentified preflight` asserts the `xt_owner` module is usable, and runs as
  part of every integration scenario.
