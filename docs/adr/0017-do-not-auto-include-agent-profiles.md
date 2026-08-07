# 0017. Warn when an agent has no profile, but don't add it automatically

**Status:** Accepted · **Date:** 2026-08-07 · **Found by:** a real VS Code session

## The problem

The Feature has two independent options:

```jsonc
"agents":   "claude,pi",          // which agents to install
"profiles": "base,claude,editor"  // which allowlists to combine
```

Nothing stopped you from naming an agent and forgetting its profile. That
combination produces a container where the agent installs, appears on your
`PATH`, starts up — and then cannot reach its own API.

This is not hypothetical. It is how the example project was configured for a
while, and the symptom was `pi.dev` sitting in `agentified denied` while `pi`
looked like it was working.

The failure reads as *"this agent is broken"*, not *"a policy decision blocked
it"*, which is the worst way for a boundary to fail: the user blames the wrong
component.

## The obvious fix, and why we didn't take it

Auto-include an agent's profile whenever that agent is installed. Naming an
agent implies wanting it to function, so the hosts are implied too.

We rejected it, for two reasons.

**The allowlist must be exactly what you wrote.** That is the whole promise of
this project. A reader of `devcontainer.json` should be able to say what the
policy is. If naming an agent silently adds hosts, the file no longer states
the policy, and the only way to know what is permitted is to run
`agentified hosts` inside a built container.

**Silently widening an allowlist is the dangerous direction.** A boundary that
quietly ends up *narrower* than intended is annoying — something breaks and you
investigate. A boundary that quietly ends up *wider* than intended fails
silently and forever, because nothing breaks. Those two errors do not deserve
equal treatment, and only one of them should ever happen by magic.

**And there is a legitimate configuration it would break.** Anthropic documents
running Claude Code against Amazon Bedrock, Google Cloud's Agent Platform,
Microsoft Foundry, or an LLM gateway through `ANTHROPIC_BASE_URL`. In those
setups model traffic never touches `api.anthropic.com`, and an operator may
have deliberately left the `claude` profile off so those hosts stay closed.
Auto-inclusion would reopen them without asking.

## What we decided

Keep the two options independent, and make the mistake loud in both places a
person would look.

**At build time**, `install.sh` warns:

```
[agentified/install] WARNING: agents includes "pi" but profiles does not.
[agentified/install]   pi will start and then fail to reach its own API.
[agentified/install]   Add "pi" to profiles, or list its hosts in allow.
```

**At verification time**, `agentified verify` turns it into a named failure:

```
agents
  FAIL the 'pi' profile is enabled
       agents includes 'pi' but profiles is 'base,claude,editor'
```

Two guards, because a warning in build output is easy to scroll past, and
`verify` is the tool the README tells people to run when something looks wrong.

## What we rejected, and why not

**A hard build failure**, matching how an unknown profile name is treated
([ADR-0005](0005-allowlists-as-named-profiles.md)). Consistent, and nothing to
miss — but it blocks the gateway/Bedrock configuration above unless we add an
opt-out option, and an option existing only to switch off a check we invented
is a poor trade for a mistake two warnings already catch.

The asymmetry with unknown profile names is deliberate: a typo like `rubyy`
has no valid interpretation, while `agents: claude` without `profiles: claude`
does.

## What it costs

- **You can still build the broken configuration.** By design — see the gateway
  case. The guards make it loud, not impossible.
- **Two places to maintain.** Adding a third agent means adding it to the loop
  in `install.sh` and in `lib/verify.sh`. Both loops are three lines and sit
  next to comments saying why.

## How it's tested

`verify` runs in every integration scenario, and `claude_and_pi` installs both
agents with both profiles — so the check is exercised in its passing state on
every run. The failing state is what the example project demonstrated in
practice before it was fixed.
