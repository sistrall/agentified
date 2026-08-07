# 0002. Use two layers of blocking, not one

**Status:** Accepted · **Date:** 2026-08-06

## The problem

We want the agent to reach `api.anthropic.com` and `github.com`, and nothing
else. There are two obvious ways to do that, and **each one is broken on its
own**.

### Option A: a proxy

A proxy is a middleman program. Instead of connecting to a website directly,
programs connect to the proxy and ask it to fetch the page. Most programs look
at environment variables called `HTTP_PROXY` and `HTTPS_PROXY` to find one.

If we run a proxy that only forwards requests to sites on our list, we get
exactly the behaviour we want — allow by *name*, which is the way humans think
about it.

**Why it's not enough on its own:** those environment variables are a polite
request, not a rule. `curl`, `git`, `npm`, `bundler` and Go programs honour
them. Plenty of other things ignore them completely. A program that ignores them
just opens a connection and leaves.

### Option B: a firewall

A firewall works at a lower level. It sees network packets and IP addresses, and
can block them regardless of what the program wanted. Nothing gets past it.

**Why it's not enough on its own:** a firewall has never heard of
`rubygems.org`. It only knows numbers like `151.101.0.70`. To allow a website
by name you'd have to look up its address when the container starts and write
that number into a rule. But big sites change addresses constantly, and use many
of them. Your rule goes stale within hours, and the symptom is that something
mysteriously stops working until you rebuild the container. This is the flaw in
most firewall scripts you'll find floating around.

## What we decided

**Use both, each doing the part it's good at.**

```
┌─ container ─────────────────────────────────────────────────┐
│                                                             │
│  the agent, running as your normal user                     │
│    │  HTTPS_PROXY=http://127.0.0.1:3128                     │
│    ▼                                                        │
│  the proxy, running as its own user "agentproxy"            │
│    │       ── checks the website name against the list ──►  │
│    │                                                        │
│  ═══════════ the firewall ═══════════                       │
│    block everything by default                              │
│    ...except traffic that never leaves the container        │
│    ...except traffic from the proxy's user account          │
└─────────────────────────────────────────────────────────────┘
```

- The **proxy** decides *which websites* are allowed. It works with names, so
  the list stays correct forever.
- The **firewall** makes the proxy impossible to skip. It doesn't care about
  names — it only enforces one thing: *the only user account allowed to reach the
  outside world is the proxy's*.

A program that ignores `HTTPS_PROXY` and tries to connect directly doesn't get
blocked by the proxy — it never reaches the proxy. It gets blocked by the
firewall, because it isn't running as the proxy's user.

How that user-account rule works is [ADR-0004](0004-only-the-proxy-user-may-leave.md).

## What it costs

- **Two things to configure and two things that can break.** We mitigate this
  with `agentified status` and `agentified verify`, which tell you which layer
  said no.
- **Failures look different depending on the layer.** The proxy returns a "403
  Forbidden", which is a clear message. The firewall returns "connection
  refused", which is vaguer. The `verify` suite deliberately tests both so you
  can recognise them.

## How it's tested

The `verify` suite checks, from inside a running container, that:

- an allowed site works *through the proxy*
- a blocked site is refused *by the proxy*
- an allowed site **also fails** when you bypass the proxy — this is the one
  that proves the firewall is doing its job and isn't secretly name-aware
- `ssh` straight out fails
