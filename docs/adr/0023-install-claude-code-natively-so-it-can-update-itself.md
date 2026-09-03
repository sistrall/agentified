# 0023. Install Claude Code natively, in the user's home, so it can update itself

**Status:** Accepted · **Date:** 2026-09-02 · **Found by:** a field report

## The problem

Someone upgraded Claude Code inside a container built by this Feature and
ended up with two of it, at two versions, one of them installed without
anything obviously asking.

This is what happened. We installed Claude Code with npm, as root, into
`/opt/agentified/npm`, and put a wrapper at `/usr/local/bin/claude`
([ADR-0014](0014-private-node-with-wrapper-commands.md)). Claude Code updates
itself, and it does so by writing new versions next to the one that is
running — which it could not do, because that directory belongs to root:

```
Warning: Can't auto-update: npm global folder isn't writable
Fix: Run claude install to switch to the native installer (no sudo)
```

`claude install` is Claude Code's own remedy, printed by `claude update`,
`claude doctor` and the `/doctor` command inside a session, which offers to
run it for you. It downloads the native build into `~/.local/share/claude/`
and puts a launcher at `~/.local/bin/claude`. Now there are two:

| | Where | Who can update it | On `PATH`? |
|---|---|---|---|
| the one we installed | `/usr/local/bin/claude` → `/opt/agentified/npm/…` | nobody without `sudo` | yes |
| the one `claude install` made | `~/.local/bin/claude` → `~/.local/share/claude/versions/…` | the user, and the updater | depends on the shell |

Which one you get is decided by whether your shell happened to add
`~/.local/bin` to `PATH`. Debian's default `.profile` does, but only for a
login shell and only if the directory existed when the shell started. So the
same container answers `claude --version` differently in different terminals,
updates land in the copy you are not running, and none of it looks like a
decision anyone made.

The underlying fact is simpler than the symptom: **Claude Code is a program
that updates itself, and we installed it somewhere it could not.**

## What we decided

**Use Anthropic's native installer, run as the workspace user, into that
user's home. Once.**

```sh
runuser -u "$REMOTE_USER" -- env -i HOME="$REMOTE_USER_HOME" ... \
  CLAUDE_CONFIG_DIR="$scratch" bash install.sh
ln -sfn "$REMOTE_USER_HOME/.local/bin/claude" /usr/local/bin/claude
```

That gives the layout the updater is built for — `~/.local/bin/claude` is a
symlink it repoints, `~/.local/share/claude/versions/` is where it writes —
owned by the user who runs it. Background updates work. `claude update` works,
without `sudo`, which the agent is denied anyway
([ADR-0019](0019-tell-the-agent-and-deny-the-tools.md)). And `claude install`,
should anyone run it again, finds the install it would have made and writes
nothing new.

`/usr/local/bin/claude` stays, as a symlink to the user's launcher rather than
a copy of anything. It is there so `claude` resolves from any `PATH` — a
`docker exec`, a cron job, a shell that never read `/etc/profile.d` — and both
names always lead to the same binary, before and after an update.

## Three things that follow

**No Node for Claude Code.** The npm package had already become a thin shell
around the same native binary; the Node we installed to run it was running
nothing. The private Node and the wrapper scripts of
[ADR-0014](0014-private-node-with-wrapper-commands.md) now exist for Pi only,
and `agents: claude` on an image with no Node installs no Node.

**No `--ignore-scripts` for Claude Code.** The reasoning of
[ADR-0013](0013-run-only-the-agents-own-install-script.md) was about npm's
dependency tree. The native installer downloads one binary, from Anthropic's
own host, and checks it against the SHA-256 in the release manifest before
running it. That is the same trust we were already extending to the package's
postinstall, with fewer parties in between.

**The install method has to be recorded.** The native installer writes
`"installMethod": "native"` into Claude Code's config directory, and the
updater checks it; without it, `claude update` warns that the method is
unknown and — again — tells you to run `claude install`. At build time the
config directory is the state volume, which is not mounted yet, so the
installer is pointed at a scratch one, and `agentified start` seeds a new
volume with that single key. An existing `.claude.json` is the user's —
settings, onboarding state, every project they have opened — and is left
alone. If it predates this change, the first `claude update` warns that the
method is unknown, records it itself, and does not warn again; we checked,
rather than editing a 40 KB config file of someone else's with `sed`.

## Why not the alternatives

- **Make the npm prefix user-writable.** Then the updater writes into
  `/opt/agentified/npm` as the user and it works, mechanically. But it is a
  layout Anthropic is steering away from — the `Fix:` line above says so —
  and `claude install` would still create the second copy the moment anyone
  followed the advice. We would be maintaining the arrangement the tool itself
  keeps trying to leave.
- **Disable updates.** `DISABLE_UPDATES` exists, and pinning is a legitimate
  choice for a team. But this is a Feature for a dev container, not a managed
  fleet, and "you cannot upgrade without rebuilding the image" is a worse
  default than "it updates like it does on your laptop". The setting is still
  there for anyone who wants it, in Claude Code's own settings file.
- **Install into the state volume, so updates survive a rebuild.** Tempting,
  and not possible at build time: the volume is mounted only at runtime
  ([ADR-0015](0015-agent-logins-in-a-per-project-volume.md)). Copying the
  image's install into the volume on first start would work, at the cost of a
  second mechanism to explain. A rebuild returning you to the image's version
  is easy to state and is what people expect of a container.

## What it costs

- **The build downloads a 200 MB binary** from `downloads.claude.ai`, where it
  used to fetch it from npm. The set of hosts the build needs has changed;
  the README's limitations say which.
- **Updates live in the container's filesystem** and are gone with a rebuild,
  which then installs whatever is current. That is the same as before, minus
  the second copy.
- **We run Anthropic's installer script at build time**, fetched from
  `claude.ai`, rather than reimplementing its download and checksum logic.
  It is saved to a file first, not piped into a shell, so a failed download
  fails the build instead of running half a script — and it comes from the
  same source as the binary it installs, so trusting one and not the other
  would be a distinction without a difference.
- **The record in the config file** is one more thing that can be missing,
  and a pre-0.4.0 volume will be missing it until the first `claude update`.
  `verify` names that, with the one-line fix.

## How it's tested

`verify`, whenever `claude` is installed:

```
PASS  claude on PATH and executable
PASS  every claude on PATH is the one native install
PASS  claude can update itself (install owned by vscode)
PASS  the config records the native install
```

The second one walks `which -a claude` and resolves every entry with
`readlink -f`; anything that does not land in
`~/.local/share/claude/versions/` fails it. That is the assertion that would
have caught the original report.

The `claude_defaults` scenario additionally runs a real `claude update`
through the proxy and fails on either of the two warnings that used to
precede the second install, and checks that no Node was installed for Claude
Code alone. `claude_and_pi` checks that Pi is still wrapped and Claude Code
is not.
