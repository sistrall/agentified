# 0013. Run only the agent's own install script, not its dependencies'

**Status:** Accepted · **Date:** 2026-08-06 · **Found by:** an integration test

## The problem

We install the agents with npm. When npm installs a package, that package — and
every package it depends on, and everything *they* depend on — is allowed to run
arbitrary code on your machine as part of the installation. These are called
lifecycle scripts, and `postinstall` is the common one.

For a coding agent's dependency tree that can be hundreds of packages, any one
of which could have been compromised. It's the classic supply-chain attack.

npm has a flag for this: `--ignore-scripts` refuses to run any of them.

## What we tried first

Just use the flag:

```sh
npm install -g --prefix /opt/agentified/npm --ignore-scripts @anthropic-ai/claude-code
```

Safe, simple, and it produces a container where the agent doesn't work:

```
Error: claude native binary not installed.

Either postinstall did not run (--ignore-scripts, some pnpm configs)
or the platform-native optional dependency was not downloaded.
```

Claude Code is distributed as a small npm package plus a compiled binary that
its `postinstall` script downloads for your specific operating system and
processor. Block the script and you get a command that exists on `PATH` and
fails the moment you run it.

The test caught this. The unhelpful version of the test — "is `claude` on the
`PATH`?" — would have passed.

## What we decided

**Install with `--ignore-scripts`, then run the postinstall of the one package
we asked for, deliberately and by name.**

```sh
npm install -g --prefix "$NPM_PREFIX" --ignore-scripts "$pkg"

# Read the top-level package's own postinstall out of its package.json
# and run exactly that, in its own directory.
script="$(node -p "try{require('$dir/package.json').scripts.postinstall||''}catch(e){''}")"
[ -n "$script" ] && ( cd "$dir" && sh -c "$script" )
```

So:

- **`@anthropic-ai/claude-code`'s own postinstall runs.** We chose to install
  that package; we're already trusting it to be our coding agent. Its install
  script is not a meaningfully larger amount of trust.
- **No dependency's install script runs.** The hundreds of packages we never
  chose, and mostly have never heard of, still can't execute anything.

That's most of the protection, without the breakage.

## Why not just drop the flag

Dropping `--ignore-scripts` entirely would also work and takes one less line.
It would also hand execution rights, during our image build, to every transitive
dependency in the tree. The whole point of this project is reducing what an
agent's environment can do to you; starting by running arbitrary third-party
code at build time would be an odd way to begin.

## What it costs

- **The build needs internet access.** The postinstall downloads a binary from
  the network. This is true of the whole build anyway — see the README's
  limitations — but it's worth knowing this specific step is a download.
- **It's a slightly unusual thing to do.** Someone reading `install.sh` might
  see `--ignore-scripts` and assume no scripts run at all. The code has a
  comment explaining it, and so does this record.
- **It relies on the package declaring `scripts.postinstall`.** A package that
  needs an `install` or `preinstall` script instead would still be broken. If
  that happens, the fix is to widen the same mechanism, not to drop the flag.

## How it's tested

The `claude_defaults` and `claude_and_pi` scenarios, and the `verify` suite,
which deliberately checks the agent **runs** rather than merely exists:

```sh
command -v claude >/dev/null && claude --version >/dev/null
```

That distinction is the entire reason this problem was caught before release.
