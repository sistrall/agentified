# 0009. Don't put proxy settings in `containerEnv`

**Status:** Accepted · **Date:** 2026-08-06 · **Found by:** the first build attempt

## The problem

Programs find the proxy through environment variables — `http_proxy`,
`https_proxy` and their uppercase twins. Something has to set them.

A Dev Container Feature has an obvious-looking place for this, a block called
`containerEnv`:

```jsonc
"containerEnv": {
  "http_proxy":  "http://127.0.0.1:3128",
  "https_proxy": "http://127.0.0.1:3128"
}
```

This is what the original design called for. It seems exactly right.

## What actually happened

The very first build failed:

```
W: Failed to fetch http://ports.ubuntu.com/... Unable to connect to 127.0.0.1:3128
E: Unable to locate package tinyproxy
```

Here's why. When you build a dev container, the tooling generates a Dockerfile
behind the scenes. `containerEnv` becomes `ENV` lines in it — and those lines
land **above** the step that runs each Feature's install script:

```dockerfile
ENV https_proxy=http://127.0.0.1:3128    ← from containerEnv
...
RUN ./devcontainer-features-install.sh   ← our install.sh, needs the internet
```

So our own installer ran with instructions to route everything through a proxy
that doesn't exist yet — it doesn't start until the container *runs*. `apt`
couldn't reach the package servers. The build died before installing anything.

And it's worse than our own build breaking. `ENV` is baked permanently into the
image, so:

- **every Feature installed after ours** would fail the same way, and
- anyone building their own image `FROM` the result would inherit the trap.

A setting that breaks unrelated Features is not one we can ship.

## What we decided

**Set the proxy variables from a shell startup file instead.**

`install.sh` writes `/etc/profile.d/90-agentified.sh`, which shells read when
they start. It also adds a line to `/etc/bash.bashrc` and `/etc/zsh/zshenv` for
shells that don't read `profile.d`.

The reason this reaches everything `containerEnv` would have is a mechanism
called **`userEnvProbe`**. When the container is running, the dev container
tooling opens a login shell, reads the environment it produces, and applies that
environment to lifecycle commands, terminals, and the editor's server process.
So the variables arrive everywhere they're needed — but only at *runtime*, which
is exactly the distinction we needed.

`install.sh` additionally starts with:

```sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
```

so that a corporate base image, or a user who adds these by hand, can't poison
our build either.

`containerEnv` is still used — for `CLAUDE_CONFIG_DIR`, `NO_PROXY` and our own
paths. Those are harmless during a build.

### `CLAUDE_CONFIG_DIR` is written in both places

`containerEnv` reaches the processes the tooling starts, and nothing else.
Anything that resets the environment — `su -l`, `cron`, `sudo -i` — drops it,
and Claude Code then falls back to `~/.claude`, off the state volume and gone at
the next rebuild ([ADR-0015](0015-agent-logins-in-a-per-project-volume.md)).

That was found through the `verify` assertion, which probes a *login* shell for
exactly the reason described below and so could never see it: it reported
`got 'unset'` on a container where the setting was correct and working
([issue #2](https://github.com/sistrall/agentified/issues/2)). Making the check
read the container environment instead would have turned it green while
asserting something weaker than the guarantee it claims to test.

So `install.sh` exports it from `/etc/profile.d/90-agentified.sh` as well, when
`claude` is among the installed agents. The image `ENV` stays; `profile.d` makes
it survive an environment reset. The assertion then passes on its own merits.

Note that CI could not have caught this. The devcontainer CLI writes
`containerEnv` into `/etc/environment`, which Debian's `su` reads back through
`pam_env` — so the probe saw the variable under the tooling the tests use, and
not under tooling that skips that step.

## What it costs

**This depends on `userEnvProbe` being switched on.** It's on by default
(`loginInteractiveShell`), but if you set `"userEnvProbe": "none"` in your
`devcontainer.json`, the variables won't reach your tools. Nothing would appear
broken — traffic just wouldn't be proxied, and would then be blocked by the
firewall, producing confusing timeouts.

So `agentified verify` checks this **explicitly**, by opening a login shell as
the workspace user and confirming `https_proxy` is set. If it isn't, you get a
named failure telling you to fix `userEnvProbe` or add the variables to
`remoteEnv` yourself, rather than a mystery.

## How it's tested

`verify` runs this check in every integration scenario:

```
PASS  https_proxy visible in a login shell (http://127.0.0.1:3128)
```

The check runs the probe as the workspace user through a **login** shell —
deliberately, because `sudo` has already stripped the environment by the time
`verify` runs, so testing the script's own environment would prove nothing.
