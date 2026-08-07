# 0006. Reject bad option values instead of quietly ignoring them

**Status:** Accepted · **Date:** 2026-08-06

## The problem

Two of our options are text that ends up inside something the computer executes:

- `allow` — hostnames that get turned into **pattern-matching expressions** for
  the proxy's filter file
- `extraCidrs` — network address ranges that get written into **firewall rules**

Text that gets turned into instructions is always a place to be careful. If
someone writes `"allow": "evil.com|.*"`, that `|.*` isn't a hostname — in
pattern-matching syntax it means "or literally anything". A single option value
could silently open the allowlist to the entire internet.

This isn't only about malice. It's mostly about typos producing a policy that
looks fine and isn't.

## What we decided

**Check every option against a strict definition of what it's allowed to be, and
fail the build if it doesn't match.**

- A hostname may contain only letters, digits, dots and hyphens; may start with
  one dot; may not have empty pieces; may not be longer than 253 characters.
- A network range must be four numbers 0–255 separated by dots, optionally
  followed by `/` and a number up to 32.
- The mode must be one of `enforce`, `learn`, `off`. Same for `dnsMode`.
- The port must be a number between 1 and 65535.
- A profile name must exist as a file, and may contain only lowercase letters,
  digits, hyphens and underscores — so nobody can write `../../etc/passwd`.

All of this runs during **`install.sh`, at image build time**. A bad value stops
the build with a clear message instead of producing a working-looking container
with a wrong policy.

## Why fail rather than skip

Because of the direction of the mistake.

If a bad `allow` entry were skipped, your policy would be **narrower** than what
you wrote. Nothing visibly breaks at build time. Days later something hangs and
you have no reason to connect it to a typo you made once.

If a bad `extraCidrs` entry were skipped, your database container would just be
unreachable and you'd blame the database.

Both are cases where the machine knows something is wrong and the human finds
out much later, expensively. Failing the build costs thirty seconds and tells
you exactly what to fix.

## What it costs

- **Some legitimate values are rejected.** IPv6 ranges in `extraCidrs`, for
  instance, or wildcards more exotic than a leading dot. If you need them,
  the validators in `files/lib/common.sh` are where to extend, and there's a
  test file next to them showing what's expected.
- **A stricter rule than the tools themselves would enforce.** The proxy would
  happily accept a more elaborate pattern. We don't let you write one, because
  hand-written patterns in a security allowlist are how mistakes happen.

## A bug this caught

The validation was originally written like this:

```sh
{
  ...check each host, return 1 if invalid...
} | sort -u
```

In shell, the left-hand side of a `|` runs in a **separate process**. So
`return 1` for an invalid host exited that separate process, and the result the
outer function reported was whatever `sort` said — which was always "fine".

Invalid entries were silently dropped and the build succeeded. Exactly the
failure mode this ADR exists to prevent, hiding inside the mechanism meant to
prevent it.

It was caught by a unit test, not by review. The fix collects into a variable
first and only sorts at the very end. The general rule: **validation that must
fail a build cannot live inside a pipeline.**

## How it's tested

`test/unit/common.bats` and `test/unit/allowlist.bats` feed the validators
deliberately nasty input and assert every one is refused:

```
''  '.'  '*'  'a b'  'a|b'  'a$b'  'evil.com|.*'  '(a)'  'a..b'
'-a.com'  'a.com-'  'a;rm -rf /'  '$(id)'  '`id`'  'a/b'  (embedded newline)
'10.0.0.0/33'  '10.0.0.256'  '0.0.0.0/0 -j ACCEPT'
```

That last one is an attempt to smuggle an extra firewall instruction through the
`extraCidrs` option. It's rejected.
