# Tailscale Userspace Networking (No Root)

## Install

Recommended installer:

```bash
chmod +x ./install-tailscale-bins.sh
./install-tailscale-bins.sh
```

On Linux, this downloads the official static tarball from
`pkgs.tailscale.com`. On macOS arm64, it uses Homebrew's `tailscale` bottle and
copies `tailscale` and `tailscaled` into `~/bin`.

Manual Linux install:

```bash
# Download and install binaries to ~/bin
curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_latest_amd64.tgz" -o /tmp/tailscale.tgz
tar -xzf /tmp/tailscale.tgz -C /tmp/
mkdir -p ~/bin
cp /tmp/tailscale_*/tailscale /tmp/tailscale_*/tailscaled ~/bin/
chmod +x ~/bin/tailscale ~/bin/tailscaled
rm -rf /tmp/tailscale.tgz /tmp/tailscale_*

# Create state directory
mkdir -p ~/.local/share/tailscale
```

## Managed Nets Script

Use `tailscale-userspace-net.sh` to manage multiple userspace Tailscale
instances. Each managed net gets its own state file, socket, log, and tmux
session under `~/.local/share/tailscale-userspace-nets/<name>/`. If `tmux` is
not installed, the script falls back to a background `tailscaled` process with a
PID file in the same directory.

```bash
chmod +x ./tailscale-userspace-net.sh

# Show locally managed userspace nets
./tailscale-userspace-net.sh list

# Create a new managed net and start the normal Tailscale login flow
./tailscale-userspace-net.sh create personal --hostname my-pc

# Start, authenticate, inspect, and stop an existing managed net
./tailscale-userspace-net.sh start personal
./tailscale-userspace-net.sh up personal
./tailscale-userspace-net.sh status personal
./tailscale-userspace-net.sh stop personal

# Print an SSH config ProxyCommand for this managed net
./tailscale-userspace-net.sh proxycommand personal

# Expose this managed net as a local SOCKS5 and HTTP CONNECT proxy
./tailscale-userspace-net.sh proxy personal 127.0.0.1:1055
```

After `create` or `up`, follow the printed Tailscale login URL. The net name is
local only; it selects which userspace daemon state and socket to use.

## SSH ProxyCommand

Print a reusable SSH `ProxyCommand` for a managed net:

```bash
./tailscale-userspace-net.sh proxycommand personal
```

Example output:

```sshconfig
ProxyCommand /path/to/tailscale-userspace-net.sh nc personal %h %p
```

Use it in `~/.ssh/config` for hosts reachable through that managed userspace
Tailscale net:

```sshconfig
Host ts-*
  ProxyCommand /path/to/tailscale-userspace-net.sh nc personal %h %p
```

The `nc` subcommand starts the managed daemon if needed, runs `tailscale up`,
waits for the backend to reach `Running`, then runs
`tailscale --socket=<net socket> nc <host> <port>`. Startup and login messages
are written to stderr so they do not corrupt SSH's proxied stdout stream.
By default, the final proxied `tailscale nc` stream is not hard-capped, because
SSH and VS Code Remote need it to stay open. Set `TAILSCALE_NC_TIMEOUT` only for
short manual tests where you want the stream killed after a fixed number of
seconds.

If the daemon died or left behind a stale socket after a network transition,
`status`, `up`, and `nc` automatically remove the stale runtime and restart the
managed daemon before retrying. Set `TAILSCALE_RECOVER_RETRIES` to control the
number of restart attempts. Startup and recovery are serialized by a per-net
lock, so concurrent SSH `ProxyCommand` invocations for the same net share one
daemon instead of launching competing `tailscaled` instances. Recovery also
cleans up duplicate `tailscaled` processes that match the managed net's exact
state and socket paths before starting a replacement. When `BASE_DIR` points at
a project-local `nets/` directory, same-name daemons left running under the old
default `~/.local/share/tailscale-userspace-nets/` path are also pruned; set
`TAILSCALE_PRUNE_LEGACY_BASE=0` to disable that.

If a previous SSH attempt exits while holding the fallback directory lock, later
attempts remove that stale `runtime.lockdir` automatically once
`TAILSCALE_LOCK_STALE_TIMEOUT` has elapsed. By default, that matches
`TAILSCALE_LOCK_TIMEOUT`.

Before opening the TCP stream, `nc` waits for the target peer to answer a single
`tailscale ping` so an SSH connection can pause while the Tailscale path comes
back. DERP relay reachability is accepted; a direct path is not required. Set
`TAILSCALE_PEER_TIMEOUT` to control that wait, or `TAILSCALE_PEER_PING=0` to
skip it. If the peer still does not answer, `nc` restarts the managed net once
before dialing SSH. Repeated SSH attempts share a cooldown so they do not
restart the same net repeatedly; set `TAILSCALE_RECONNECT_COOLDOWN` to control
that window.

## Local Proxy

Expose a managed net as a local proxy:

```bash
./tailscale-userspace-net.sh proxy personal 127.0.0.1:1055
```

This restarts the managed daemon with both `--socks5-server` and
`--outbound-http-proxy-listen` on the same listen address. The listener setting
is saved under the managed net directory, so later `start` calls keep the proxy
enabled.

## Start Daemon (tmux)

```bash
tmux new-session -d -s tailscaled \
  "$HOME/bin/tailscaled --tun=userspace-networking \
    --state=$HOME/.local/share/tailscale/tailscaled.state \
    --socket=$HOME/.local/share/tailscale/tailscaled.sock 2>&1"
```

## Authenticate (first time only)

```bash
sleep 2
~/bin/tailscale --socket=~/.local/share/tailscale/tailscaled.sock up
```

Follow the printed URL to log in.

## Verify

```bash
~/bin/tailscale --socket=~/.local/share/tailscale/tailscaled.sock status
```

## Shell Alias (optional)

Add to `~/.bashrc`:

```bash
alias tailscale='~/bin/tailscale --socket=~/.local/share/tailscale/tailscaled.sock'
```

## Manage tmux Session

```bash
tmux attach -t tailscaled        # attach to see logs
tmux ls                          # verify session exists
tmux kill-session -t tailscaled  # stop daemon
```
