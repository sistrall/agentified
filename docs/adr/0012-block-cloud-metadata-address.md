# 0012. Block the cloud metadata address, even for the proxy

**Status:** Accepted · **Date:** 2026-08-06

## The problem

There's a special IP address — `169.254.169.254` — that means something
dangerous on cloud machines.

If your dev container runs on a cloud server (AWS, GCP, Azure, or a hosted
development environment like Codespaces), anything inside the container can
fetch that address over plain unencrypted HTTP and get back **the machine's
cloud credentials**. No authentication. It's a deliberate feature of cloud
platforms, intended for the machine's own software.

For us it's a hole straight through everything else we've built. All the careful
website allowlisting is irrelevant if the agent can grab the host's credentials
from a numeric address in one request.

That address sits inside a range called *link-local*, `169.254.0.0/16`, which is
reserved for local, non-routed purposes.

## What we decided

**Reject the entire `169.254.0.0/16` range, for every user in the container —
including the proxy's.**

This is the one rule that applies to `agentproxy` too. Everywhere else, the
proxy is trusted to make outgoing connections
([ADR-0004](0004-only-the-proxy-user-may-leave.md)). Here it isn't, because a
request to the metadata address would look like a perfectly ordinary HTTP
request to the proxy.

## Where the rule goes, and why order matters

Rules are checked top to bottom, first match wins. So this rule has to come
**before** two others, or it does nothing:

1. **Before the proxy's allow rule** — otherwise the proxy matches "allowed
   user" first and never reaches the metadata block.
2. **Before the "already-established connection" rule** — firewalls normally
   allow packets belonging to a connection that was already permitted. If a
   connection to the metadata address got started, that rule would keep it
   alive.

This ordering is asserted by unit tests specifically, because it's invisible
when reading the rules casually and completely breaks the protection when wrong.

## The exception we had to add

Some container runtimes hand out a **DNS server inside that same range**.
Blanket-rejecting `169.254.0.0/16` would then break all name resolution in the
container, and the symptom ("nothing works") would give no hint about the cause.

So the rule generator looks at the container's actual DNS configuration first.
If a DNS server is in the link-local range, it emits a narrow exception —
**that specific address, on the DNS port only** — placed above the range
rejection. Everything else in the range, including the metadata address, stays
blocked.

This is a good example of why generating rules as text
([ADR-0010](0010-write-firewall-rules-as-text.md)) pays off: this conditional
carve-out has a unit test that would be genuinely awkward to write otherwise.

## What it costs

- **A more complicated rule than "reject the range".** The carve-out is
  conditional on the container's configuration, which is one more thing to
  understand.
- **It doesn't help if metadata is reachable another way.** Some platforms also
  expose metadata through a hostname. Those go through the proxy and are subject
  to the allowlist, so they aren't reachable unless someone adds them — but this
  rule doesn't specifically catch them.

## How it's tested

`test/unit/firewall.bats`:

- the metadata rejection appears **before** the proxy's allow rule
- the metadata rejection appears **before** the established-connection rule
- when the DNS server is inside the link-local range, its narrow exception is
  emitted **above** the range rejection

`verify`, in every integration scenario:

```
PASS  cloud metadata endpoint unreachable
```
