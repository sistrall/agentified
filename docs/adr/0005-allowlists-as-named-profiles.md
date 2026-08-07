# 0005. Ship allowlists as named profiles you mix and match

**Status:** Accepted · **Date:** 2026-08-06

## The problem

Which websites should be allowed? There is no single right answer, because it
depends entirely on your project:

- A Ruby project needs `rubygems.org`.
- A Python project needs `pypi.org` and `files.pythonhosted.org`.
- A Rust project needs `crates.io` *and* `static.crates.io` *and*
  `index.crates.io`.
- Everyone needs GitHub.
- Everyone using VS Code or Zed needs the editor's own download sites, for
  reasons covered below.

The tempting shortcut is to hardcode one list of eight domains that works for
the author's project. That's what most firewall scripts of this kind do, and
it's why they're unusable outside a Node project in VS Code.

## What we decided

Ship the lists as **named profiles** — one small text file each — and let people
compose them:

```jsonc
"profiles": "base,claude,editor,ruby"
```

The shipped profiles are `base`, `claude`, `pi`, `editor`, `ruby`, `node`,
`python`, `rust` and `go`. Anything else you need goes in the `allow` option:

```jsonc
"allow": "gems.mycompany.internal,.cdn.mycompany.internal"
```

The file format is one hostname per line. A leading dot means "this and
everything under it":

```
rubygems.org        →  only rubygems.org
.rubygems.org       →  rubygems.org and index.rubygems.org and anything else under it
```

Comments with `#` and blank lines are ignored, so the profiles can explain
themselves.

## Please include the `editor` profile

This is the one that catches everyone out, so it's worth spelling out.

When you open a project in a dev container, VS Code and Zed don't just connect
to it. They **download and install a server component inside the container**
after it starts, and then extensions and language servers download themselves
too. Those downloads come from the editor's own websites.

Our firewall switches on shortly after the container starts. If the editor's
download sites aren't allowed, the editor's own setup gets strangled — and the
symptom is not "a domain is missing", it's "the container is broken and I don't
know why".

So `editor` is in the default profile list, and you should have a specific
reason before removing it.

## What it costs

- **The profiles will drift.** Sites add new CDN domains; profiles go stale.
  This is why `learn` mode exists ([ADR-0007](0007-learn-mode-switches-the-filter-off.md))
  — so you can find out what's actually being requested rather than guessing.
- **A profile is a judgement call.** `claude.txt` includes error-reporting and
  analytics domains, because Claude Code uses them. If you'd rather it couldn't
  reach those, build your own list with `allow` and drop the profile.

## Why a typo is a hard error

If you write `"profiles": "base,rubyy"`, the build **fails**.

It would be easy to skip the unknown name and carry on. We deliberately don't,
because the result would be a container whose policy is *quietly stricter* than
the one you wrote. You wouldn't notice at build time. You'd notice three days
later when something hangs for no visible reason.

A policy that's accidentally too tight is the worst failure mode available here,
precisely because it looks like nothing happened. See
[ADR-0006](0006-reject-bad-options-loudly.md).

## How it's tested

`test/unit/allowlist.bats` covers the compiler:

- exact names match only themselves — `example.com` must **not** match
  `evil.example.com`
- dotted names match the site and its subdomains, but not `notexample.com` or
  `example.com.evil.net`
- dots are escaped, so `api.github.com` can't match `apiXgithub.com`
- profiles combine and de-duplicate
- an unknown profile name fails loudly
- **every shipped profile compiles, and every line in it is a valid hostname** —
  so a typo in a profile file is caught by the test suite, not by a user
