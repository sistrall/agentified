# 0011. Spell out every command the user is allowed to `sudo`

**Status:** Accepted · **Date:** 2026-08-06 · **Found by:** reading the sudoers manual carefully

## The problem

Setting up firewall rules requires administrator privileges. The dev container's
lifecycle commands run as *your* user, not as an administrator. So they use
`sudo`:

```jsonc
"onCreateCommand": "sudo /usr/local/bin/agentified start --proxy-only"
```

For that to work without asking for a password, we have to grant permission in a
file under `/etc/sudoers.d/`. The question is how wide to make that grant.

Giving the workspace user unrestricted `sudo` would be simplest and would defeat
much of the point. So we grant only the specific commands the tool needs.

## The trap

The obvious way to write it:

```
vscode ALL=(root) NOPASSWD: /usr/local/bin/agentified start, \
                            /usr/local/bin/agentified stop, \
                            /usr/local/bin/agentified status
```

This looks like it says "you may run `agentified start`". It doesn't.

`sudo` matches the **entire command line**, arguments included. That entry
authorises `agentified start` with *exactly no further arguments*. It does
**not** authorise:

```
sudo agentified start --proxy-only
```

...which is the exact command in `onCreateCommand`. The container would have
come up, hit `onCreate`, and sat there waiting for a password nobody can type,
in a build with no interactive terminal.

## What we decided

**List every permitted invocation explicitly**, including argument variants:

```
vscode ALL=(root) NOPASSWD: \
  /usr/local/bin/agentified start, \
  /usr/local/bin/agentified start --proxy-only, \
  /usr/local/bin/agentified stop, \
  /usr/local/bin/agentified status, \
  /usr/local/bin/agentified preflight, \
  /usr/local/bin/agentified verify, \
  /usr/local/bin/agentified hosts, \
  /usr/local/bin/agentified learn, \
  /usr/local/bin/agentified denied, \
  /usr/local/bin/agentified logs, \
  /usr/local/bin/agentified logs *
```

Verbose, and correct. The one wildcard is on `logs`, which takes a line count.

Then, because a broken sudoers file can lock you out of a machine entirely,
`install.sh` validates it before finishing:

```sh
visudo -cf /etc/sudoers.d/agentified
```

A syntax error fails the **build**, where it's a thirty-second fix, rather than
producing a container you can't administer.

## Why not just use a wildcard

We could write `/usr/local/bin/agentified *` and be done. We don't, because the
list is documentation: it's the complete, reviewable set of privileged
operations this Feature grants. Anyone auditing the container can read that file
and know exactly what the workspace user can do as an administrator. A wildcard
would hide future additions.

## What it costs

- **Adding a subcommand means remembering to add it here**, or it silently
  requires a password. The `verify` suite runs several of these commands through
  `sudo`, so a forgotten entry tends to show up as a test failure.
- **The user can still run `sudo agentified stop`**, which tears the boundary
  down. That's intentional — you need an escape hatch when the allowlist is
  wrong and you're trying to work. But it does mean this is not a boundary
  against something *deliberately* trying to get out, only against accidents.
  If you want to raise that bar, delete the `stop` line from
  `/etc/sudoers.d/agentified`.

## How it's tested

Indirectly but thoroughly: every integration scenario's container comes up
through the real lifecycle, which means `sudo agentified start --proxy-only`
must succeed non-interactively or the test hangs and fails. The test scripts
then call `sudo agentified verify`, `hosts`, `learn` and `denied` — so any
missing grant surfaces immediately.
