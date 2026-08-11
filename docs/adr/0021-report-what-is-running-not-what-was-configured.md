# 0021. Report what is running, not what was configured

**Status:** Accepted · **Date:** 2026-08-11 · **Found by:**
[issue #3](https://github.com/sistrall/agentified/issues/3)

## The problem

`status` computed the mode from the config file on every invocation:

```sh
MODE="${AGENTIFIED_MODE:-${MODE:-enforce}}"     # bin/agentified
...
printf 'mode       : %s\n' "$MODE"
```

That is the mode *this invocation would apply if it started the proxy* — not
the mode the running proxy was started with. The two come apart the moment
anyone uses the override we document:

```console
$ sudo AGENTIFIED_MODE=learn agentified start
$ sudo agentified status | grep '^mode'
mode       : enforce            # the proxy is in learn mode, permitting everything

$ curl -o /dev/null -w '%{http_code}\n' --proxy http://127.0.0.1:3128 https://example.com/
200                             # 403 before learn mode was switched on
```

Every other line of `status` describes live state — the pid, the compiled
allowlist, the actual `OUTPUT` chain — which is exactly what made the one
computed line so easy to believe. And `status` is the command the README, and
the agent notes in [ADR-0019](0019-tell-the-agent-and-deny-the-tools.md), tell
you to run when something looks wrong.

A boundary that is *down* is bad. A boundary that is *open while asserting it
is closed* is worse, because nothing prompts you to look.

## What we decided

**`start` records what it applied; `status` and `verify` read that back.**

`/run/agentified/state` gets the effective mode, whether the firewall was
applied or deferred, the dns mode, and the profiles and allow list that were
compiled in. `status` reports those, and annotates the line when they differ
from the config file:

```
mode       : learn   (config: enforce)
```

Three things follow from that record:

- When nothing is running, the mode line does not name a mode at all — it says
  `(nothing running) — config: enforce`. Defaulting to `enforce` there would be
  the same lie in a quieter voice.
- `verify` asserts the two agree, by name. Run against a learn-mode proxy it
  used to fail the enforce assertions, which reads as "your allowlist is
  broken" rather than "you are in learn mode".
- `status` says out loud when the running boundary permits everything. Learn
  mode is a diagnostic setting, not a middle ground, and a word in a summary
  block was not carrying that.

The record lives in `/run`, next to the rendered ruleset, and is read only when
the proxy is actually up. A file that outlived its proxy — after a plain
`docker restart`, say — would resurrect the previous run's answer, which is the
failure we are fixing rather than a fix for it.

## Why not read it back from the proxy instead?

We could infer the mode from `/etc/agentified/tinyproxy.conf`, which is written
at start: `FilterDefaultDeny Yes` means enforce. That is one fewer file, and it
is genuinely observed rather than recorded.

It is also narrower. It cannot express "the firewall half never ran", which is
a real state — `start --proxy-only` is how the boundary comes up at
`onCreateCommand` — and it cannot say which profiles were compiled. And nothing
stops the config file being rewritten after the proxy that loaded it started,
so "observed" would be doing less work than it appears to.

## The liveness check underneath it

Everything above rests on knowing whether the proxy is up, and the check we had
did not:

```sh
pgrep -u agentproxy -x tinyproxy >/dev/null 2>&1
```

`pgrep` matches zombies. tinyproxy daemonises, so its processes are re-parented
to PID 1 — and a container's PID 1 is usually `sleep infinity`, which never
reaps. Every proxy that had ever exited stayed visible, so a stopped boundary
reported itself as `up` forever, and the warning below never fired. The check
now reads `/proc/<pid>/stat` and skips zombies. `agentified running` exposes it
as an exit status, with no output and no root required.

## What it costs

One more file in `/run`, and a `status` line that is longer when the running
boundary disagrees with the config. Both are the price of the output being
true.

A proxy started by an older version has no record. `verify` says so and skips
the comparison, rather than inventing agreement.

## How it's tested

- `test/unit/state.bats` covers the record: every field round-trips, a missing
  key fails rather than answering, keys match whole (`RUN_MODE` is not answered
  by `RUN_MODELLING`), and values are parsed rather than sourced — they include
  user-supplied option strings and an unprivileged `status` reads them.
- `boundary_only` restarts the proxy under an override and asserts `status`
  follows the proxy, names the config, and that `verify` fails on the mismatch
  by name.
- `learn_mode` asserts `status` says the proxy is wide open in as many words.
