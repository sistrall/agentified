# 0015. Keep agent logins in a per-project volume

**Status:** Accepted · **Date:** 2026-08-06

## The problem

Coding agents need you to log in. If that login lives inside the container's
normal filesystem, it disappears every time the container is rebuilt — and
rebuilding is something you do often while setting a dev container up.

Logging into Claude Code after every rebuild would make this Feature annoying
enough that people would stop using it.

## What we decided

Ask the tooling for a **Docker volume** — storage that lives outside the
container and survives rebuilds — and point the agents at it.

```jsonc
"mounts": [{
  "source": "agentified-state-${devcontainerId}",
  "target": "/agent-state",
  "type": "volume"
}]
```

`${devcontainerId}` is a placeholder the tooling replaces with a value unique to
*this dev container on this machine*. That gives one storage volume per project:
your work project and your side project don't share a login, and neither can
read the other's credentials.

## Two agents, two different mechanisms

The agents disagree about where credentials live, so we handle them differently:

**Claude Code** reads an environment variable, so we just set it:

```jsonc
"containerEnv": { "CLAUDE_CONFIG_DIR": "/agent-state/claude" }
```

**Pi** always uses `~/.pi` with no way to override it. So at startup we replace
that path with a symbolic link pointing into the volume:

```
/home/vscode/.pi  →  /agent-state/pi
```

Pi writes to `~/.pi` exactly as it expects, and the bytes land in the volume.

The linking step is careful about what it finds:

- already the right link → do nothing
- a link pointing somewhere else → replace it, and say so
- **a real directory that already exists → leave it completely alone** and print
  a warning that state won't persist

That last case matters. If someone already has a `~/.pi` directory with real
data in it, silently deleting it to make room for our link would be destroying
user data to fix a convenience feature. A warning and a degraded experience is
the right trade.

## What it costs

- **Volumes accumulate.** Every dev container you build gets one, and removing
  the container doesn't remove it. `make clean` cleans up this project's; for
  others, `docker volume ls` and `docker volume prune` are the tools.
- **The credentials sit in a Docker volume on your machine**, unencrypted, like
  most local development credentials. It's the same exposure as `~/.aws` or
  `~/.npmrc` on your laptop, but worth knowing it exists.
- **`${devcontainerId}` can't be used at build time**, only at runtime — that's
  a rule of the format, because build results are meant to be shareable. Which
  is fine here: we only need it for the mount.

## The gap in our testing

Being honest about this one.

The tests confirm the volume is mounted, is owned by the right user, is
writable, and that Pi's symlink points into it. They do **not** confirm that a
real login survives a real rebuild — that would mean authenticating an actual
agent account in CI, which we can't do.

So the mechanism is verified and the end-to-end promise is only argued. It's
listed as an open question in the [ADR index](README.md).

## How it's tested

`verify`, in every scenario:

```
PASS  state volume writable by vscode
PASS  CLAUDE_CONFIG_DIR points at the state volume
PASS  pi home directory links into the state volume
```

The `CLAUDE_CONFIG_DIR` check reads the variable from **the user's own
environment** through a login shell, not from the verify script's environment —
because `sudo` strips the container's variables, so checking the script's own
environment would silently prove nothing.
