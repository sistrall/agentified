# 0019. Tell the agent the boundary is deliberate, and deny it the tools anyway

**Status:** Accepted · **Date:** 2026-08-07

## The problem

[ADR-0018](0018-guardrail-not-a-sandbox.md) recorded an agent dismantling the
network boundary because it looked like a fault. The key observation was that
this was **cooperative behaviour, not adversarial**: the agent hit a blocked
host, saw it had `sudo`, and helpfully fixed what appeared to be a broken
container.

If the failure is cooperative, a cooperative countermeasure should work. Nobody
had told the agent the breakage was on purpose.

## What we decided

Two layers, controlled by one option, `agentPolicy`:

| Value | What it does |
|---|---|
| `strict` (default) | notes **and** deny rules |
| `notes-only` | advisory text only |
| `off` | neither |

### Layer 1: tell it (advisory)

A short document explaining that the allowlist is deliberate policy, that
routing around it removes a control the user deliberately installed, and —
critically — **what to do instead**:

```bash
agentified denied     # every host the policy refused
agentified hosts      # the allowlist as compiled
```

These work without `sudo`, deliberately. An agent denied `sudo` and given no
way to diagnose is merely stuck; one that can see exactly which host was
refused can report something useful. Agents route around obstacles partly
because they have no better move available, so the notes supply one.

It reaches the agents through the only hooks each offers:

- **Claude Code**: seeded as `CLAUDE.md` in its config directory (the state
  volume), and only when absent — the volume persists across rebuilds and may
  hold the user's own memory file.
- **Pi**: it has no managed-settings equivalent, but accepts
  `--append-system-prompt <file>`, and the flag is repeatable, so a user
  passing their own composes. The wrapper from
  [ADR-0014](0014-private-node-with-wrapper-commands.md) injects it.

This layer is advisory. An injected instruction overrides it exactly as easily
as it overrides anything else, so it does nothing for prompt injection.

### Layer 2: deny it (mechanical)

Claude Code reads managed settings from `/etc/claude-code/managed-settings.json`,
a scope its documentation states cannot be overridden by user, project or local
settings. We install a root-owned `permissions.deny` list there.

The deny is **mechanical rather than advisory**: the tool call is refused before
it runs, so the agent does not get to reason past it in the moment. That is the
important difference from layer 1.

We deny broadly — `Bash(sudo *)` rather than an enumeration of
`sudo iptables`, `sudo agentified stop` and so on. Narrow rules are whack-a-mole
and sidestepped by `sudo bash -c '...'`. The cost is that the agent cannot
`apt-get install`, which is arguably correct: an agent that needs root should
be asking you.

`disableBypassPermissionsMode` is set, because a bypass mode that skipped the
deny list would make the rest theatre.

Two details that matter and are easy to get wrong:

- The documented syntax is `Bash(cmd *)`. The prefixed form `Bash(command:rm *)`
  is **explicitly ignored with a startup warning**, because it would be
  bypassable by a compound command. A unit test asserts that form never appears
  in our file: a deny rule that silently matches nothing is worse than no rule,
  because it looks like protection.
- Claude Code matches each subcommand of a compound command independently
  (`&&`, `||`, `;`, `|`, `&`, newlines), so `foo && sudo bar` still hits the
  `sudo` rule.

The deny list also protects itself: editing `/etc/claude-code/managed-settings.json`
requires root, and root requires `sudo`, which is denied.

## What this does and does not achieve

**It converts the observed failure from a silent bypass into a report.** That is
the case that actually happens, and it is now handled.

**It does not make this a sandbox.** The agent still *has* `sudo` — the base
image grants it. An agent that deliberately set out to escalate could edit the
policy file. The change is that doing so is now a deliberate act rather than an
incidental one, and there is no longer an accidental path.

That distinction is the whole value, and it must not be oversold.
[ADR-0018](0018-guardrail-not-a-sandbox.md)'s framing stands unchanged: this is
a guardrail, not a sandbox.

## Alternatives rejected

**Narrow deny rules.** Precise, and defeated by `sudo bash -c`. Broad-with-an-
option is the better trade.

**Removing the workspace user's `sudo`.** Would actually close the hole, and
would break the human's `apt-get install` too, and means a Feature stomping a
privilege the base image deliberately granted. If it happens it must be a
separate opt-in.

**Nothing, on the grounds that it is bypassable.** The bar is not "unbypassable"
— nothing in-container can be. The bar is "does it stop the thing that actually
happened", and it does.

## How it's tested

Unit tests assert the deny list covers the escape routes, that the ignored
`Bash(command:...)` form never appears, that bypass mode is disabled, and that
the notes offer an alternative action rather than only prohibitions.
`agentified verify` asserts the files are installed, root-owned, not
user-writable, that the notes reach both agents, and that `agentified denied`
still works without `sudo`.

End to end, in a real container, Claude Code's debug log shows the rules
loading into the policy scope:

```
[DEBUG] Applying permission update: Adding 14 deny rule(s) to destination
        'policySettings': ["Bash(sudo *)","Bash(su *)","Bash(iptables *)", ...]
```

and an authenticated session asked to run `sudo iptables -L` answered:

> The command was denied by the permission layer before it ever ran — `sudo` is
> blocked for me by the container's agentified policy, exactly as intended.

Both layers, working together: refused mechanically, and understood as
deliberate rather than as a fault.

**Not tested**: whether the notes change behaviour under an injected
instruction. They almost certainly do not, and we do not claim they do.
