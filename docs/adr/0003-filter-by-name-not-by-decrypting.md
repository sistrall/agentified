# 0003. Filter by website name; don't decrypt the agent's HTTPS traffic

**Status:** Accepted · **Date:** 2026-08-06

## The problem

Our proxy needs to decide whether to allow a connection. But almost all traffic
is HTTPS — encrypted. Can the proxy even see where it's going?

There are two levels of detail we could work at:

1. **Just the website name.** "This connection is going to `github.com`."
2. **The full request.** "This is a `POST` to `github.com/gists` with this
   content."

Level 2 is obviously more powerful. It's also much more invasive to get.

## What we decided

**Work at level 1 only. Never decrypt anything.**

This is possible because of how proxies and HTTPS fit together. When a program
wants an HTTPS page through a proxy, it doesn't just send the encrypted traffic.
It first sends a small plain-text message to the proxy:

```
CONNECT api.github.com:443 HTTP/1.1
```

That's the program saying "please open a pipe to this address for me". The
website name is **right there, unencrypted**, because the proxy needs it to know
where to connect. Everything after that is encrypted and the proxy just shuffles
bytes back and forth without understanding them.

So the proxy can check that one line against our allowlist and either open the
pipe or refuse. We get name-based filtering for free.

## Why not decrypt (the "MITM" approach)

To see level 2 detail you'd run the proxy as a "man in the middle": it would
terminate the agent's HTTPS connection, decrypt it, look inside, then make its
own connection onwards. To stop every program from screaming about a forged
certificate, you have to install a custom certificate authority into the
container and convince every tool to trust it.

In practice that means:

- installing a CA certificate and hoping the system trust store is enough
- Node needs `NODE_EXTRA_CA_CERTS` set, separately
- Python, Ruby, Go and Java each have their own trust store or flag
- anything doing "certificate pinning" breaks outright and cannot be fixed
- and now there is a private key inside the container that can decrypt
  everything the agent does

The realistic outcome is you spend a week making `npm install` work again. We'd
rather ship something where `npm`, `bundle` and `gh` work on day one.

## What it costs

**This is the single biggest limitation of the whole project, and it's worth
understanding clearly.**

`github.com` is on the allowlist, because the agent needs it to do its job. We
can see that the agent is talking to `github.com`. We *cannot* see whether it's
reading a file or publishing your API keys to a public gist.

Every allowed website is, in principle, a way for data to get out. Allowlisting
by name reduces the number of doors; it does not put a guard at each one.

So this is a defence against **accidents**: a prompt injection attack telling
the agent to upload your `.env` to a random server, a compromised npm package
phoning home, an agent misreading an instruction. It is not a defence against
something determined and clever.

If you need level 2, the next step is a tool called mitmproxy, which can enforce
rules about methods and URL paths. That's noted as an open question in the
[ADR index](README.md), not a plan.

## How it's tested

`test/unit/proxy.bats` checks the generated proxy configuration contains no
certificate or interception settings, and the integration scenarios confirm real
HTTPS requests to allowed sites succeed with the container's normal certificate
trust — no extra setup, no `NODE_EXTRA_CA_CERTS`.
