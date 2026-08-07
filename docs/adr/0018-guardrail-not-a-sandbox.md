# 0018. This is a guardrail, not a sandbox — and the docs must say so first

**Status:** Accepted · **Date:** 2026-08-07 · **Found by:** watching an agent route around the boundary

## What happened

Pi was installed in the example container without its allowlist profile, so it
could not reach `pi.dev`. It noticed the failure, noticed it had passwordless
`sudo`, and began reconfiguring the container to get through.

Nobody told it to. It was not jailbreaking, and no injected instruction was
involved. It hit an obstacle that looked like a misconfiguration and set about
fixing it, which is what a capable agent is *supposed* to do.

## Why this matters more than the old wording admitted

The README already said this was "not a cage for a determined agent". That
framing was wrong in a way that mattered.

It implied the boundary holds under normal conditions and fails only against a
rare, adversarial model. The truth is the opposite: **the boundary holds only
until an agent finds it inconvenient**, and a capable agent finds it
inconvenient in the ordinary course of doing its job. The bypass is not an edge
case. It is the default behaviour of the thing we are bounding.

It also damages the headline claim. We sell this as a defence against prompt
injection — but an injected "fetch this from evil.example.com" is followed by
exactly the same helpful reflex that routes around a blocked host. The defence
and the bypass are the same behaviour, so the defence cannot be relied on
against the attack.

## The structural fact

```
$ sudo -l
User vscode may run the following commands:
    (root) NOPASSWD: /usr/local/bin/agentified start, ... stop, ... status
    (root) NOPASSWD: ALL
```

The second line is from the base image. `mcr.microsoft.com/devcontainers/base`
and its relatives grant the workspace user unrestricted passwordless `sudo`.

So the careful enumeration in
[ADR-0011](0011-spell-out-every-allowed-sudo-command.md) — every permitted
argument vector, `visudo -cf` validation — grants a strict *subset* of a
privilege the image already grants in full. It remains correct for images that
do not hand out blanket `sudo` (our `root_remote_user` scenario, a hardened
base), and it is decorative everywhere else.

And there is no in-container fix. Whatever rules we install with `NET_ADMIN`,
in-container root can flush. An enforcement mechanism cannot be reliably
enforced against something that has root inside the same boundary.

## What we decided

**Lead with the limitation, in the README, above the feature list.**

Not a bullet in a limitations section at the bottom — a callout in the opening,
before anyone decides to adopt it. A security tool that oversells itself is
worse than no tool, because it converts a known risk into a false sense of
safety. That is the one genuinely harmful thing this project could ship.

The honest framing:

- **Effective** against traffic that does not deliberate: a compromised
  package's install script, a runtime phoning home, telemetry, a `curl` in a
  build script. In one real session it blocked Copilot endpoints, Azure
  telemetry and a cloud metadata probe that nobody had asked for.
- **Not effective** against the agent itself, once the agent has `sudo`.

"Guardrail, not a sandbox" is the phrase, and it is now the first thing the
README says about what this is.

## What we are not doing

**Pretending a narrower sudoers grant fixes it.** It does not, while the base
image grants `NOPASSWD: ALL`.

**Quietly stripping the user's `sudo`.** A Feature that removes a privilege the
base image deliberately granted would be a surprising, non-additive change,
and would break the human's `apt-get install` too. If it happens it must be
opt-in — see below.

## Where this goes next

Three directions, in increasing order of how much they actually help and how
much they cost:

1. **Tell the agent the boundary is deliberate.** The observed failure was
   cooperative: the agent believed it was fixing a fault. An instruction file
   saying "this is policy, not a bug — report the blocked host instead of
   routing around it" converts a silent bypass into a useful message. Cheap,
   and it addresses the case that actually happens. It is advisory only, so it
   does nothing against injection.

2. **Deny the tool calls mechanically.** Claude Code reads managed settings from
   `/etc/claude-code/managed-settings.json`, which no user, project or local
   settings file can override. A root-owned `permissions.deny` list covering
   `Bash(sudo iptables:*)` and friends is mechanical rather than advisory: the
   agent does not get to reason past it in the moment. It is still defeatable
   by an agent that deliberately escalates, but that is a different and much
   less likely act than routing around an obstacle.

3. **Move enforcement out of the container.** A sidecar the workload routes
   through, with no `NET_ADMIN` inside. This is the only structurally sound
   answer, and it contradicts
   [ADR-0001](0001-ship-as-a-devcontainer-feature.md): it is no longer one
   additive line in an existing single-container config. That makes it a
   different product, not a patch, and it is the honest long-term shape.

Directions 1 and 2 are worth building. Neither turns the guardrail into a
sandbox, and the documentation must not imply otherwise.

## How it's tested

It isn't, and cannot be — "a sufficiently capable agent works around this" is
not an assertion a test suite can make. What *is* tested is that the boundary
holds against everything that does not deliberate, which is the claim we are
now careful to limit ourselves to.
