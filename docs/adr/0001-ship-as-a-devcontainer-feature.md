# 0001. Ship this as a Dev Container Feature, not a ready-made image

**Status:** Accepted · **Date:** 2026-08-06

## The problem

A dev container is a Docker container your editor opens your project inside, so
everyone on the team gets the same tools without installing anything on their
own machine. It's described by a file called `.devcontainer/devcontainer.json`.

We want to put a coding agent (Claude Code, Pi) into that container and stop it
from reaching random places on the internet. There are a few ways to ship that,
and they differ mostly in **how much of your existing setup they destroy**.

| Approach | What it means | The catch |
|---|---|---|
| A ready-made image | You change `"image"` to point at ours | You lose your own image, and everything you installed in it |
| A Docker Compose stack | You replace your `docker-compose.yml` with ours | Same problem, one level up |
| A command-line wrapper | You run `sometool run claude` in a terminal | Your editor doesn't know about it, so "Open in Container" doesn't use it |
| **A Feature** | You add one entry to `"features"` | **Nothing else changes** |

## What we decided

Ship it as a **Dev Container Feature**.

A Feature is a small, installable add-on for a dev container. You list it in
your `devcontainer.json` and the tooling runs its install script inside your
image while building it:

```jsonc
"features": {
  "ghcr.io/sistrall/agentified/agentified:0": {
    "agents": "claude",
    "profiles": "base,claude,editor"
  }
}
```

That's the whole integration. Your base image, your other tools, your
`postCreateCommand` — all untouched.

## Why this and not something else

The Feature format happens to allow exactly the things this job needs, which is
not true of most add-on formats:

- **`capAdd`** — request extra permissions for the container. We need
  `NET_ADMIN` so we're allowed to set up firewall rules inside it.
- **`mounts`** — ask for a storage volume. We use it so your agent login
  survives a container rebuild.
- **`containerEnv`** — set environment variables.
- **Lifecycle hooks** — run commands at specific moments, like "just after the
  container starts".
- **`installsAfter`** — say "install me after the Node feature", so we don't
  fight over the same files.

And crucially, when several Features each ask for something, the tooling merges
them sensibly rather than picking a winner: permissions from all of them are
combined.

The other big reason: **both VS Code and Zed understand Features**, including
Features referenced by a local folder path. A command-line wrapper can't work
with either editor's "Reopen in Container" button, because the editor is the one
starting the container, not you.

## What it costs

- **We only get to add things, never change the base image.** If your image is
  missing something we need, we have to install it ourselves at build time.
- **We can't control what other Features do.** Another Feature installed after
  ours could undo our environment variables. `installsAfter` only helps for
  Features we can name in advance.
- **A Feature's settings can't be templated into its own metadata.** This turns
  out to matter — see [ADR-0009](0009-keep-proxy-settings-out-of-containerenv.md).

## How it's tested

The whole integration test suite runs the real thing: `devcontainer features
test` builds an actual container from a real base image with the Feature
installed, then runs assertions inside it. Nine scenarios cover different
option combinations and two different base images. See
[ADR-0016](0016-test-in-two-layers.md).
