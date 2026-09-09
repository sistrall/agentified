# 0024. Put the proxy variables in `containerEnv` after all

**Status:** Accepted · **Date:** 2026-09-09 · **Supersedes:**
[ADR-0009](0009-keep-proxy-settings-out-of-containerenv.md) · **Found by:** a
field report about editor servers, and a read of the devcontainer CLI source

## The problem

[ADR-0009](0009-keep-proxy-settings-out-of-containerenv.md) decided that
`http_proxy` and friends must not go in the Feature's `containerEnv`, because
`containerEnv` is emitted as `ENV` *above* the feature install layers and would
point build-time `apt`/`curl`/`npm` at a port that does not exist until runtime.
They went to `/etc/profile.d/90-agentified.sh` instead, and `userEnvProbe` was
supposed to carry them everywhere `containerEnv` would have.

Two things were wrong with that.

**The mechanism does not exist.** In `@devcontainers/cli` the generated
Dockerfile template has always ordered the pieces like this
(`src/spec-configuration/containerFeaturesConfiguration.ts`):

```dockerfile
#{featureLayer}          ← the feature install scripts run here
#{containerEnv}          ← ENV lines land *below* them
ARG _DEV_CONTAINERS_IMAGE_USER=root
USER $_DEV_CONTAINERS_IMAGE_USER
#{devcontainerMetadata}
#{containerEnvMetadata}
```

That order holds in every release checked, back to v0.25.0. And it does not
even apply to us: `generateContainerEnvsV1` filters to
`internalVersion !== '2'`, so a **v2 Feature's `containerEnv` is never written
as `ENV` at all**. It travels in the devcontainer metadata label, is merged in
`imageMetadata.ts`, and is applied as `docker run -e` when the container starts
(`src/spec-node/singleContainer.ts`). Runtime only. It cannot reach the build.

Whatever produced the build failure quoted in ADR-0009, it was not this, under
this tooling. The most likely explanation is that it was observed through the
VS Code Dev Containers extension, a separate closed-source implementation whose
generated Dockerfile we cannot inspect.

**`userEnvProbe` does not cover what we claimed.** It covers a lot: the probe
result becomes `remoteEnv` and does reach the editor server and the language
servers it spawns. But it only covers processes *the devcontainer tooling
starts*. Anything else — and, more to the point, any tooling that does not
implement the probe — gets nothing.

That is not hypothetical. [ADR-0022](0022-a-boundary-that-did-not-start-must-say-so.md)
already records that **Zed applies a Feature's `capAdd`, `mounts` and
`containerEnv`** while ignoring its lifecycle commands. Zed applies the exact
mechanism ADR-0009 refused to use, and does not apply the one it chose instead.

The failure this produces is the bad kind. A process that never saw
`https_proxy` egresses directly, the L3 backstop drops it, and
`agentified denied` stays **empty** — because the request never reached the
proxy to be refused. It reads as "the container is broken", not "a domain is
missing", which is precisely what
[`editor.txt`](../../src/agentified/files/profiles/editor.txt) says we are
trying to avoid.

## What we decided

**Put the four proxy variables in the Feature's `containerEnv`**, where they
reach every process in the container regardless of shell, login state, or which
editor built it.

```jsonc
"containerEnv": {
  "http_proxy":  "http://127.0.0.1:3128",
  "https_proxy": "http://127.0.0.1:3128",
  "HTTP_PROXY":  "http://127.0.0.1:3128",
  "HTTPS_PROXY": "http://127.0.0.1:3128"
}
```

`/etc/profile.d/90-agentified.sh` **stays**, for the two jobs `containerEnv`
cannot do — see below. This is now the same belt-and-braces arrangement
`CLAUDE_CONFIG_DIR` has had since
[ADR-0015](0015-agent-logins-in-a-per-project-volume.md), and for the same
reasons.

`install.sh` still starts by unsetting any inherited proxy variables. That was
never about our own `containerEnv`; it is about a corporate base image, and it
still earns its place.

## What it costs

**The port is hardcoded.** A Feature's `containerEnv` cannot interpolate a
Feature option. The CLI substitutes only `localEnv`, `containerEnv`,
`localWorkspaceFolder`, `containerWorkspaceFolder` and `devcontainerId`
(`src/spec-common/variableSubstitution.ts`) — there is no `${featureOption:...}`.
So `containerEnv` advertises 3128 whatever `proxyPort` says.

With a non-default `proxyPort`, shells read the real port from `profile.d` and
everything else gets 3128, where nothing is listening. Two things stop that
from being silent:

- `install.sh` warns at build time, printing the exact `containerEnv` block to
  paste into your `devcontainer.json`. That override works because config
  metadata is merged *after* Feature metadata with `Object.assign`
  (`imageMetadata.ts`), so yours wins.
- `verify` compares the container environment against the port the proxy is
  actually running on and names the mismatch.

**`profile.d` is still needed**, so we keep two sources of the same truth:

- it carries the *configured* port, which `containerEnv` cannot; and
- `containerEnv` does not survive anything that resets the environment —
  `su -l`, `cron`, `sudo -i`. `profile.d` does.

**A container whose boundary never started now refuses connections instead of
dropping them.** Every process gets `https_proxy` pointing at a dead port. That
is louder than the old silent-direct-then-blocked behaviour, and
[ADR-0022](0022-a-boundary-that-did-not-start-must-say-so.md) already exists to
name it.

## How it's tested

`verify` asserts both guarantees separately, because they fail independently:

```
PASS  https_proxy in the container environment (http://127.0.0.1:3128)
PASS  https_proxy visible in a login shell (http://127.0.0.1:3128)
```

The first reads `/proc/1/environ`. PID 1 was started with exactly the
environment `docker run -e` applied, and `sudo` has stripped `verify`'s own by
the time it runs — so this is the honest place to read the container
environment, and it is what the old login-shell probe could never see.
