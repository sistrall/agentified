# 0020. Profiles follow tools, not frameworks — and agent-facing hosts are a second axis

**Status:** Accepted · **Date:** 2026-08-10

## The question

"Can we add a `svelte` profile?" seems obviously reasonable. Answering it
properly turned out to change how we think about what a profile is *for*.

## What we measured

A complete SvelteKit lifecycle in a learn-mode container — `sv create`,
`npm install`, `npm run build`, `svelte-check`, all succeeding — reached
exactly one host:

```
registry.npmjs.org
```

Which the `node` profile already covers. A `svelte` profile built from that
measurement would be a verbatim duplicate.

**That generalises.** A framework is an npm package. React, Vue, Next, Nuxt,
Astro and Solid would all produce the same one-line answer. Shipping a profile
per framework would give us a dozen files that are `node` with a different
name, each carrying a `# verified:` header implying someone checked something.

So: **no framework profiles.**

## What that answer missed

The person who asked wasn't thinking about builds. They had noticed that the
**Svelte MCP server is blocked by default** — which is a genuinely Svelte-
specific host, and genuinely something you want when working on Svelte.

Measuring again, this time at the agent layer:

| Variant | Needs |
|---|---|
| Remote, `https://mcp.svelte.dev/mcp` | `mcp.svelte.dev` |
| Local, `npx @sveltejs/mcp` | npm only — docs bundled, offline after install |

So a `svelte` profile *is* justified, for a reason the original measurement was
structurally incapable of finding.

## The blind spot this exposed

`test/agentified/toolchains.sh` runs real package managers and asserts nothing
was refused ([ADR-0016](0016-test-in-two-layers.md)). It is a good check and it
verified `node`, `python` and `ruby` honestly.

It measures **builds**. It is blind to everything the *agent* reaches for:

- MCP servers, local and remote
- documentation lookups the agent performs directly
- any tool invoked by the agent rather than by the build

For a project whose entire purpose is putting a boundary around agents, that is
the wrong half to have automated. It is why the `claude` profile could be
missing `platform.claude.com` while every test passed, and why this question
had to be answered by hand.

## What we decided

**Name a profile after the thing that has hosts, not after the thing you are
writing.** Two axes, both legitimate:

- **Build tooling** that fetches something other than npm packages —
  `playwright` fetches browser binaries from its own CDN, so `npm install`
  succeeds and `playwright install` is what fails.
- **Agent tooling** — MCP servers, docs endpoints. `svelte` is now this kind of
  profile, and says so in its own header.

A profile file must say which it is, and what was measured. `svelte.txt` opens
by stating that the build toolchain needs nothing beyond `node`, so nobody
re-derives that later.

**And when someone asks for a profile, measure before agreeing.** Learn mode
plus `agentified denied` answers it in about ten minutes, and the answer here
was neither the requested "yes" nor the measured "no".

## What it costs

- **A judgement call per request.** "Is this a tool with hosts, or a framework?"
  has no mechanical test. The measurement resolves it.
- **The blind spot is documented, not fixed.** Extending automated verification
  to agent workflows means driving an MCP handshake and a docs lookup in CI.
  That is worth doing and is not done. Listed in the
  [ADR index](README.md) as open.

## How it's tested

Both new profiles were verified end to end in an enforcing container: compiled
into the allowlist, all four hosts reachable, an actual MCP `initialize`
handshake to `https://mcp.svelte.dev/mcp` returning 200, and `example.com`
still refused by the proxy.

The provenance test from [ADR-0005](0005-allowlists-as-named-profiles.md)
covers their headers, and every entry is a valid hostname.
