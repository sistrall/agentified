# This container has a deliberate network boundary

You are running inside a container configured with **agentified**. Outbound
network access is restricted to an allowlist. This is **intentional policy set
by the person you are working for** — it is not a misconfiguration, and it is
not a bug for you to fix.

## When a network request fails

A refused connection here means *the policy said no*, not *the container is
broken*. The two look identical from inside, so assume the former.

**Do not** try to work around it. Specifically, do not:

- change firewall rules (`iptables`, `ip6tables`)
- stop, restart, or reconfigure the proxy
- edit anything under `/etc/agentified/`
- edit sudoers, or use `sudo` to obtain network access
- set `NO_PROXY`, unset `https_proxy`, or otherwise route around the proxy

Doing any of that removes a security control your user deliberately put in
place, and it does so without their knowledge. Even when it would let you
complete the task, it is the wrong trade to make on someone else's behalf.

## What to do instead

Find out what was blocked. These work without `sudo`:

```bash
agentified denied     # every host the policy refused
agentified hosts      # the allowlist as it was actually compiled
agentified status     # current mode and configuration
```

Then **tell your user**, naming the host and the fix. For example:

> `pi.dev` was blocked by the network policy. If it should be reachable, add it
> to the `allow` option in `.devcontainer/devcontainer.json` and rebuild:
>
> ```jsonc
> "agentified": { "allow": "pi.dev" }
> ```
>
> If it belongs to a toolchain, the matching profile may be the better fix —
> `agentified hosts` shows what is currently permitted.

That is genuinely more useful than getting through. A blocked host is often a
real signal: a dependency phoning home, telemetry nobody asked for, or a
missing entry your user will want to know about.

## Why you cannot simply fix it yourself

`sudo` is denied for you by policy. That restriction is deliberate and it is
not an obstacle to route around — it exists precisely because an agent that
helpfully removes its own guardrails defeats their purpose.

If you genuinely believe the policy is wrong, say so and explain why. That is
a decision for your user to make, not for you to make silently.
