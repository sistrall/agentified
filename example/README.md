# agentified example

A throwaway project with [agentified](../README.md) installed, so you can see
the network boundary working before putting it on anything real.

## Open it

> **Run `make sync-example` in the repo root first**, once. This folder
> references the Feature from `.devcontainer/agentified/`, a copy the Makefile
> generates and `.gitignore` hides — the devcontainer tooling will not read a
> Feature from outside `.devcontainer/`, and will not follow a symlink either.
> Without that copy the container build fails immediately.

Then open this folder in VS Code and choose **Reopen in Container**, or in Zed
choose **Reopen in Dev Container**. From the repo root, `make up && make shell`
does the same thing headlessly.

## Try it

Every terminal greets you with these. The first is the interesting one:

```bash
./demo.sh                 # prove the boundary works — about two seconds
sudo agentified status    # what is allowed, and what is running
sudo agentified verify    # the full assertion suite, ~20 checks
```

`./demo.sh` walks through four steps:

1. **Your toolchain still works** — `api.github.com` is on the allowlist, so it
   returns 200 through the proxy.
2. **A dependency tries to phone home** — `example.com` is not on the
   allowlist, so the proxy refuses it.
3. **It skips the proxy and connects directly** — the firewall refuses it, *even
   though the address is one the allowlist permits*. This is the step worth
   watching: proxy settings are advisory and a program can ignore them, so the
   firewall is what makes the boundary real.
4. **Your policy recorded what it stopped** — `agentified denied` lists it.

## What this example is configured with

```jsonc
"agents":   "claude",
"profiles": "base,claude,editor,ruby",
"allow":    "gems.mycompany.internal"
```

So `claude` is installed and sandboxed, GitHub / Anthropic / the editors /
RubyGems are reachable, plus one made-up internal host to show the `allow`
option. Everything else is refused.

## Using this as a starting point for your own project

Copy `.devcontainer/devcontainer.json` across, swap the local `./agentified`
reference for the published one, and adjust `profiles` to your stack.

Two bits of scaffolding exist only to demo the thing, and you'll want them gone:

**The welcome banner.** Delete one file:

```bash
rm .devcontainer/welcome.sh
```

The next terminal you open is silent. No rebuild — `postCreateCommand` adds a
*guarded source* of that file to `~/.bashrc`, not a copy of its contents, so
removing the file is enough. The leftover `[ -r ... ] && . ...` line is inert
and harmless; delete the `postCreateCommand` too if you want it properly tidy.

**The demo script.** `rm demo.sh` — nothing references it.

What to keep: the `features` block. That is agentified itself.

## Things worth trying next

- Add a domain to `allow` in `.devcontainer/devcontainer.json`, rebuild, and
  watch `sudo agentified hosts` pick it up.
- Switch `"mode"` to `"learn"`, browse around, then run `sudo agentified learn`
  to see every host your work actually asked for.
- Run `claude` itself. It is installed, sandboxed, and its login is kept in a
  volume that survives rebuilds.
