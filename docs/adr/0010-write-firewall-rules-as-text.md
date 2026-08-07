# 0010. Write the firewall rules as text, then load them in one go

**Status:** Accepted · **Date:** 2026-08-06

## The problem

The normal way to set up firewall rules in a script is to run one command per
rule:

```sh
iptables -P OUTPUT DROP                          # block everything by default
iptables -A OUTPUT -o lo -j ACCEPT               # ...except internal traffic
iptables -A OUTPUT -m owner --uid-owner 999 -j ACCEPT   # ...except the proxy
iptables -A OUTPUT -j REJECT
```

Two things are wrong with this.

**It isn't atomic.** Look at the order. The first line blocks everything. The
rules that allow the traffic we want land afterwards — milliseconds later, but
afterwards. In between, the container has no network at all. If the script dies
partway through (a typo, a missing kernel module), you're left in that state
with no obvious way to tell what happened.

**It can't be tested.** Every one of those lines needs `NET_ADMIN` privileges
and a real network namespace. To check that the rules are in the right order you
must build a container, run it privileged, apply the rules and inspect them.
That's a minutes-long feedback loop for logic that's mostly about **ordering** —
which is exactly the kind of thing you get wrong.

## What we decided

Split it in two:

1. **A function that only prints text.** It produces a complete ruleset in the
   format the `iptables-restore` command reads:

   ```
   *filter
   :OUTPUT DROP [0:0]
   :AGENTIFIED_OUT - [0:0]
   -A OUTPUT -j AGENTIFIED_OUT
   -A AGENTIFIED_OUT -o lo -j ACCEPT
   -A AGENTIFIED_OUT -d 169.254.0.0/16 -j REJECT ...
   -A AGENTIFIED_OUT -m owner --uid-owner 999 -j ACCEPT
   -A AGENTIFIED_OUT -j REJECT ...
   COMMIT
   ```

2. **Two lines that load it.** `iptables-restore` reads the whole document and
   applies it as a single transaction.

Everything interesting — rule order, the DNS policy, the user-account rule, the
address ranges — lives in step 1, which touches nothing.

## Why this is better

- **It's atomic.** The kernel switches from the old ruleset to the new one in
  one step. There is no moment where the policy is "block" but the exceptions
  haven't arrived.
- **It's testable on a laptop.** The rendering function is a pure text
  transformation, so we can call it directly from unit tests with no
  privileges, no container and no network. They run in under a second.
- **It's faster.** One command instead of a dozen or more.
- **Failures are visible.** The generated ruleset is written to
  `/run/agentified/rules.v4` before being loaded. If loading fails you have the
  exact document that was rejected.

## A related choice: our own chain

The rules live in a named group called `AGENTIFIED_OUT` rather than directly in
the built-in `OUTPUT` group, with a single line sending traffic there.

That means `agentified status` can show *just our policy* instead of everything
in the container, and it leaves room for a future mode that merges with existing
rules instead of replacing them.

## What it costs

- **A layer of indirection.** You can't read the script and see `iptables`
  commands; you read a function that prints them. In exchange, you can read the
  *test* file and see precisely what ordering is guaranteed.
- **We replace the whole filter table.** Inside a dev container there's nothing
  else there, so this is safe. It would not be safe on a host machine.

## How it's tested

`test/unit/firewall.bats`, no privileges required, including the
ordering assertions that are the whole point:

- the default policy is "block"
- internal traffic is allowed before anything else is considered
- the cloud metadata address is rejected **before** the proxy's allow rule and
  **before** the "already-established connection" rule — otherwise the block
  would be bypassable ([ADR-0012](0012-block-cloud-metadata-address.md))
- blocked traffic is logged, rate-limited, before the final reject
- the last rule is always a reject, so nothing falls through unnoticed
- `resolver-only` emits rules for exactly the container's own DNS servers;
  `blocked` emits none; `open` emits a general one
- a malformed address range **fails rendering** rather than producing a broken
  ruleset
- the output is a well-formed document: starts with `*filter`, ends with
  `COMMIT`
