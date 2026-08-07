# 0008. Start the proxy early, switch the firewall on late

**Status:** Accepted · **Date:** 2026-08-06

## The problem

A dev container runs your commands at several defined moments, in this order:

| Moment | When it happens | Typically used for |
|---|---|---|
| `onCreate` | once, right after the container is first created | early setup |
| `updateContent` | after source code is available | |
| `postCreate` | once, after creation finishes | `npm ci`, `bundle install` |
| `postStart` | **every** time the container starts | services, daemons |
| `postAttach` | every time your editor connects | |

We have two things to switch on: the proxy and the firewall. Putting them in
the wrong slots causes two different, equally annoying failures.

**If the proxy starts too late:** the environment tells every program to use a
proxy at port 3128. Your project's `postCreate` runs `bundle install`, which
dutifully connects to port 3128, where nothing is listening. Your build fails
before the agent has even been used.

**If the firewall starts too early:** it's on during `postCreate`, and the first
missing domain fails your container *build* rather than showing up later as a
blocked request. That's a much worse first experience — you can't get into the
container to run `agentified denied` and find out what happened.

## What we decided

Split them:

```jsonc
"onCreateCommand":  "sudo agentified start --proxy-only",
"postStartCommand": "sudo agentified start"
```

- **Proxy at `onCreate`** — the earliest slot available, so it's listening well
  before anything in your project runs.
- **Firewall at `postStart`** — after `postCreate` has finished installing your
  dependencies.

And `agentified start` is **idempotent**: running it again when things are
already up is safe. It restarts the proxy cleanly and reloads the firewall
rules. That's what makes the second call at `postStart` correct rather than a
conflict, and it means a plain container restart (which runs `postStart` but not
`onCreate`) brings both up.

## What this deliberately leaves open

During `postCreate`, your dependency installation goes through the proxy and is
still allowlisted — but it is **not** additionally constrained by the firewall.
Something that ignores proxy settings could reach the internet during that
window.

We think that's the right trade. `postCreate` runs your own project's setup
commands, which you wrote; the threat model here is the *agent* misbehaving
later, and the agent isn't running yet.

If you'd rather lock it down during installation too, move the firewall to
`onCreateCommand` and accept that a missing domain fails the build.

## A related decision: no `no-new-privileges`

There's a container hardening flag called `no-new-privileges` that stops
processes gaining extra permissions. It's generally a good idea.

We do not set it, because it **breaks `sudo`** — and both lifecycle commands
above depend on `sudo` to do their work. Turning it on would give you a
container where the boundary never comes up at all.

The alternative would be moving enforcement into the container's `entrypoint`,
which runs as root before anything else and needs no `sudo`. That would let us
add the flag. It also means losing the ability to re-run `agentified start`
after changing something without restarting the whole container, and it behaves
unpredictably when several Features each want an entrypoint. Not worth it yet.

## What it costs

- **The `sudo` permission has to exist**, which means the workspace user can
  also run `sudo agentified stop`. See
  [ADR-0011](0011-spell-out-every-allowed-sudo-command.md) for how that's
  narrowed, and the README's limitations for what it means.
- **A window during `postCreate`** where the firewall isn't active, as above.

## How it's tested

Every integration scenario exercises the real lifecycle: `devcontainer up` runs
`onCreate` and then `postStart` exactly as a user's editor would. If the split
were wrong, the containers wouldn't come up. The `verify` suite then confirms
both layers are actually in force afterwards.
