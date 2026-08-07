# 0007. Learn mode switches the filter off; it does not invert it

**Status:** Accepted · **Date:** 2026-08-06

## The problem

Nobody knows their allowlist in advance. You add the Feature, and then
`bundle install` hangs, and you have no idea which website it wanted.

So we want a mode where the proxy lets everything through but **writes down**
every site that was asked for. Work normally for a day, then read the list and
turn it into your allowlist. This is the single feature that most reduces the
pain of adopting something like this.

The question is how to implement it.

## The trap

Our proxy (tinyproxy) has a setting called `FilterDefaultDeny`. It sounds like a
simple on/off switch for strictness, and the obvious implementation of learn
mode is to flip it:

```
FilterDefaultDeny No     # "don't deny by default" — sounds permissive?
Filter "/etc/agentified/allowlist.filter"
```

**This is backwards, and dangerously so.**

That setting doesn't control strictness. It controls **what the filter file
means**:

| Setting | What the file is |
|---|---|
| `FilterDefaultDeny Yes` | an **allowlist** — only these sites are permitted |
| `FilterDefaultDeny No` | a **blocklist** — these sites are the only ones **blocked** |

So flipping it while still loading the file gives you the exact inverse of what
you wanted: every site you carefully allowed is now blocked, and the entire rest
of the internet is open. It would look like it was working — traffic flows! —
while doing precisely the wrong thing.

## What we decided

In `learn` mode, **don't load a filter file at all.** Leave out the `Filter` and
`FilterDefaultDeny` lines entirely and let the proxy do what it does with no
filter configured: forward everything.

The recording comes from a separate setting, `LogLevel Connect`, which is on in
every mode. It writes a log line for each connection.

```bash
sudo agentified learn > .devcontainer/observed-domains.txt
```

Then review it, fold what you want into `allow`, and switch back to `enforce`.

## The firewall stays on

Worth being explicit: `learn` mode relaxes the **proxy**, not the **firewall**.
The user-account rule from [ADR-0004](0004-only-the-proxy-user-may-leave.md) is
still in force.

That matters for the quality of your recording. If programs could bypass the
proxy during learn mode, they wouldn't appear in the log, and your allowlist
would be missing exactly the things that ignore proxy settings. Because
everything must go through the proxy, the log is complete.

## The other direction: `denied`

Once you're in `enforce` mode, `learn` still works but is less useful. So
there's a companion command:

```bash
sudo agentified denied
```

which lists the sites the filter **refused**. That answers "what did the policy
just block?" directly, which is usually the question you actually have.

## What it costs

- **`learn` is not a safe mode to leave switched on.** The proxy is wide open.
  It's a temporary diagnostic setting, not a middle ground.
- **Log parsing is fragile.** We extract hostnames from proxy log lines with
  pattern matching. If the proxy's log format changes in a future version, this
  breaks. That's why parsing is a separate, unit-tested function with a real log
  file as a fixture, rather than being buried in the CLI.

## How it's tested

`test/unit/proxy.bats`:

- `enforce` mode produces a config containing `FilterDefaultDeny Yes` and a
  `Filter` line
- `learn` mode produces a config containing **neither** — this test exists
  specifically to stop someone "simplifying" it back into the trap
- every mode keeps `LogLevel Connect`

`test/unit/allowlist.bats` runs the log parsers against a fixture log file and
checks both requested and refused hostnames come out correctly.

The `learn_mode` integration scenario proves it end to end in a real container:
a non-allowlisted site succeeds through the proxy, appears in `agentified
learn`, and **still fails** when the proxy is bypassed.
