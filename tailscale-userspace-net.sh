#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_SOURCE" == */* ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_ABS="$SCRIPT_DIR/$(basename "$SCRIPT_SOURCE")"
else
  SCRIPT_ABS="$(command -v "$SCRIPT_SOURCE" || true)"
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_ABS")" && pwd)"
fi

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # Optional local overrides for TAILSCALE_BIN, TAILSCALED_BIN, and state paths.
  source "$SCRIPT_DIR/.env"
fi

BASE_DIR="${TAILSCALE_MANAGE_DIR:-${BASE_DIR:-$HOME/.local/share/tailscale-userspace-nets}}"
DEFAULT_BASE_DIR="$HOME/.local/share/tailscale-userspace-nets"
TAILSCALE_BIN="${TAILSCALE_BIN:-$HOME/bin/tailscale}"
TAILSCALED_BIN="${TAILSCALED_BIN:-$HOME/bin/tailscaled}"
TMUX_BIN="${TMUX_BIN:-tmux}"
SESSION_PREFIX="${TAILSCALE_SESSION_PREFIX:-tailscale-net}"
START_TIMEOUT="${TAILSCALE_START_TIMEOUT:-15}"
UP_TIMEOUT="${TAILSCALE_UP_TIMEOUT:-20}"
STATUS_TIMEOUT="${TAILSCALE_STATUS_TIMEOUT:-5}"
NC_TIMEOUT="${TAILSCALE_NC_TIMEOUT:-0}"
RECOVER_RETRIES="${TAILSCALE_RECOVER_RETRIES:-2}"
LOCK_TIMEOUT="${TAILSCALE_LOCK_TIMEOUT:-30}"
LOCK_STALE_TIMEOUT="${TAILSCALE_LOCK_STALE_TIMEOUT:-$LOCK_TIMEOUT}"
PEER_TIMEOUT="${TAILSCALE_PEER_TIMEOUT:-30}"
PEER_PING="${TAILSCALE_PEER_PING:-1}"
RECONNECT_COOLDOWN="${TAILSCALE_RECONNECT_COOLDOWN:-60}"
PRUNE_LEGACY_BASE="${TAILSCALE_PRUNE_LEGACY_BASE:-1}"

usage() {
  cat <<'USAGE'
Manage multiple Tailscale userspace-networking instances without root.

Usage:
  tailscale-userspace-net.sh list
  tailscale-userspace-net.sh create NAME [tailscale-up-flags...]
  tailscale-userspace-net.sh start NAME
  tailscale-userspace-net.sh up NAME [tailscale-up-flags...]
  tailscale-userspace-net.sh status NAME
  tailscale-userspace-net.sh proxy NAME [LISTEN_ADDR]
  tailscale-userspace-net.sh proxycommand NAME
  tailscale-userspace-net.sh nc NAME HOST PORT
  tailscale-userspace-net.sh stop NAME
  tailscale-userspace-net.sh logs NAME
  tailscale-userspace-net.sh path NAME

Examples:
  ./tailscale-userspace-net.sh list
  ./tailscale-userspace-net.sh create personal --hostname mini-twitter-personal
  ./tailscale-userspace-net.sh create work --login-server https://login.tailscale.com
  ./tailscale-userspace-net.sh up personal --accept-routes --ssh
  ./tailscale-userspace-net.sh proxy personal 127.0.0.1:1055
  ./tailscale-userspace-net.sh proxycommand personal

Environment:
  TAILSCALE_MANAGE_DIR      Base directory for per-net state.
  TAILSCALE_BIN            Path to tailscale. Default: ~/bin/tailscale
  TAILSCALED_BIN           Path to tailscaled. Default: ~/bin/tailscaled
  TAILSCALE_SESSION_PREFIX tmux session prefix. Default: tailscale-net
  TAILSCALE_UP_TIMEOUT     Seconds to wait for BackendState=Running. Default: 20
  TAILSCALE_NC_TIMEOUT     Optional hard cap for the final nc stream. Default: 0
  TAILSCALE_RECOVER_RETRIES
                            Restart attempts when a daemon/socket is stale. Default: 2
  TAILSCALE_LOCK_TIMEOUT    Seconds to wait for per-net startup lock. Default: 30
  TAILSCALE_LOCK_STALE_TIMEOUT
                            Seconds before an ownerless lockdir is stale. Default: TAILSCALE_LOCK_TIMEOUT
  TAILSCALE_PEER_TIMEOUT    Seconds to wait for peer reconnect before nc. Default: 30
  TAILSCALE_PEER_PING       Set 0 to skip peer readiness ping before nc. Default: 1
  TAILSCALE_RECONNECT_COOLDOWN
                            Seconds to suppress repeated peer-triggered restarts. Default: 60
  TAILSCALE_PRUNE_LEGACY_BASE
                            Kill same-name daemons from the default base dir. Default: 1

The script uses tmux when it is available. If tmux is not installed, it starts
tailscaled as a background process and stores a PID file with the net state.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ensure_tools() {
  [[ -x "$TAILSCALE_BIN" ]] || die "tailscale not executable at $TAILSCALE_BIN"
  [[ -x "$TAILSCALED_BIN" ]] || die "tailscaled not executable at $TAILSCALED_BIN"
}

validate_name() {
  local name="$1"

  [[ -n "$name" ]] || die "net name is required"
  [[ "$name" != "." && "$name" != ".." ]] || die "invalid net name: $name"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
    die "invalid net name '$name'; use letters, numbers, dot, underscore, or hyphen"
  }
}

net_dir() {
  printf '%s/%s\n' "$BASE_DIR" "$1"
}

socket_path() {
  printf '%s/tailscaled.sock\n' "$(net_dir "$1")"
}

state_path() {
  printf '%s/tailscaled.state\n' "$(net_dir "$1")"
}

log_path() {
  printf '%s/tailscaled.log\n' "$(net_dir "$1")"
}

pid_path() {
  printf '%s/tailscaled.pid\n' "$(net_dir "$1")"
}

proxy_listen_path() {
  printf '%s/proxy.listen\n' "$(net_dir "$1")"
}

reconnect_stamp_path() {
  printf '%s/reconnect.stamp\n' "$(net_dir "$1")"
}

lock_path() {
  printf '%s/runtime.lock\n' "$(net_dir "$1")"
}

lock_dir_path() {
  printf '%s/runtime.lockdir\n' "$(net_dir "$1")"
}

session_name() {
  printf '%s-%s\n' "$SESSION_PREFIX" "$1"
}

quote_arg() {
  printf '%q' "$1"
}

path_mtime() {
  local path="$1"

  if stat -f %m "$path" >/dev/null 2>&1; then
    stat -f %m "$path"
  else
    stat -c %Y "$path"
  fi
}

lock_owner_path_for_dir() {
  printf '%s/owner\n' "$1"
}

is_lockdir_stale() {
  local lock_dir="$1"
  local owner_file owner now mtime

  owner_file="$(lock_owner_path_for_dir "$lock_dir")"
  if [[ -f "$owner_file" ]]; then
    read -r owner <"$owner_file" || owner=""
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi

  [[ "$LOCK_STALE_TIMEOUT" == "0" ]] && return 1
  now="$(date +%s)"
  mtime="$(path_mtime "$lock_dir" 2>/dev/null || printf '%s\n' "$now")"
  ((now - mtime >= LOCK_STALE_TIMEOUT))
}

remove_lockdir_if_stale() {
  local lock_dir="$1"

  [[ -d "$lock_dir" ]] || return 1
  is_lockdir_stale "$lock_dir" || return 1
  rm -rf "$lock_dir" >/dev/null 2>&1 || return 1
}

run_with_timeout() {
  local seconds="$1"
  shift

  if [[ "$seconds" == "0" ]]; then
    "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
      $t = shift @ARGV;
      if ($t <= 0) {
        exec @ARGV or die "exec: $!\n";
      }
      $pid = fork();
      die "fork: $!\n" unless defined $pid;
      if ($pid == 0) {
        exec @ARGV or die "exec: $!\n";
      }
      $timed_out = 0;
      local $SIG{ALRM} = sub {
        $timed_out = 1;
        kill "TERM", $pid;
        select undef, undef, undef, 0.2;
        kill "KILL", $pid;
      };
      alarm $t;
      waitpid($pid, 0);
      $status = $?;
      alarm 0;
      exit 124 if $timed_out;
      exit 128 + ($status & 127) if $status & 127;
      exit($status >> 8);
    ' "$seconds" "$@"
  else
    "$@"
  fi
}

with_net_lock() {
  local name="$1"
  local waited=0
  local lock_dir
  local locked_pid
  local status
  shift

  validate_name "$name"
  mkdir -p "$(net_dir "$name")"

  if command -v flock >/dev/null 2>&1; then
    flock -w "$LOCK_TIMEOUT" "$(lock_path "$name")" "$SCRIPT_ABS" __locked "$name" "$@"
    return $?
  fi

  lock_dir="$(lock_dir_path "$name")"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if remove_lockdir_if_stale "$lock_dir"; then
      printf 'removed stale lock: %s\n' "$lock_dir" >&2
      continue
    fi
    if ((waited >= LOCK_TIMEOUT)); then
      die "timed out waiting for lock: $lock_dir"
    fi
    sleep 1
    waited=$((waited + 1))
  done

  trap 'rm -rf "$lock_dir" >/dev/null 2>&1 || true' EXIT
  "$SCRIPT_ABS" __locked "$name" "$@" &
  locked_pid="$!"
  printf '%s\n' "$locked_pid" >"$(lock_owner_path_for_dir "$lock_dir")"
  if wait "$locked_pid"; then
    status=0
  else
    status=$?
  fi
  trap - EXIT
  rm -rf "$lock_dir" >/dev/null 2>&1 || true
  return "$status"
}

has_tmux() {
  command -v "$TMUX_BIN" >/dev/null 2>&1 && "$TMUX_BIN" start-server >/dev/null 2>&1
}

is_tmux_running() {
  has_tmux && "$TMUX_BIN" has-session -t "$(session_name "$1")" >/dev/null 2>&1
}

read_pid() {
  local pid_file
  pid_file="$(pid_path "$1")"

  [[ -f "$pid_file" ]] || return 1
  read -r REPLY <"$pid_file"
  [[ "$REPLY" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$REPLY"
}

is_pid_running() {
  local pid
  pid="$(read_pid "$1" 2>/dev/null)" || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

socket_responding() {
  local name="$1"
  local socket
  socket="$(socket_path "$name")"

  [[ -S "$socket" ]] || return 1
  [[ -x "$TAILSCALE_BIN" ]] || return 1
  run_with_timeout "$STATUS_TIMEOUT" "$TAILSCALE_BIN" --socket="$socket" status --json >/dev/null 2>&1
}

is_running() {
  socket_responding "$1"
}

has_tracked_runtime() {
  is_tmux_running "$1" || is_pid_running "$1"
}

tmux_child_pid() {
  local name="$1"

  has_tmux || return 1
  "$TMUX_BIN" list-panes -t "$(session_name "$name")" -F '#{pane_pid}' 2>/dev/null | head -n 1
}

managed_daemon_pids() {
  local name="$1"
  local socket state

  socket="$(socket_path "$name")"
  state="$(state_path "$name")"
  ps -axo pid=,command= \
    | awk -v socket="--socket=$socket" -v state="--state=$state" '
        $2 ~ /(^|\/)tailscaled$/ && index($0, socket) && index($0, state) {
          print $1
        }
      '
}

legacy_daemon_pids() {
  local name="$1"
  local socket state

  [[ "$PRUNE_LEGACY_BASE" == "0" ]] && return 0
  [[ "$BASE_DIR" != "$DEFAULT_BASE_DIR" ]] || return 0

  socket="$DEFAULT_BASE_DIR/$name/tailscaled.sock"
  state="$DEFAULT_BASE_DIR/$name/tailscaled.state"
  ps -axo pid=,command= \
    | awk -v socket="--socket=$socket" -v state="--state=$state" '
        $2 ~ /(^|\/)tailscaled$/ && index($0, socket) && index($0, state) {
          print $1
        }
      '
}

script_path() {
  printf '%s\n' "$SCRIPT_ABS"
}

configured_proxy_listen() {
  local proxy_file
  proxy_file="$(proxy_listen_path "$1")"

  [[ -f "$proxy_file" ]] || return 1
  read -r REPLY <"$proxy_file"
  [[ -n "$REPLY" ]] || return 1
  printf '%s\n' "$REPLY"
}

validate_listen_addr() {
  local listen_addr="$1"

  [[ -n "$listen_addr" ]] || die "proxy listen address is required"
  [[ "$listen_addr" != *[[:space:]]* ]] || die "proxy listen address cannot contain whitespace"
  [[ "$listen_addr" == *:* ]] || die "proxy listen address must include a port, for example 127.0.0.1:1055"
}

wait_for_socket() {
  local name="$1"
  local i
  local socket
  socket="$(socket_path "$name")"

  for ((i = 0; i < START_TIMEOUT; i++)); do
    [[ -S "$socket" ]] && return 0
    sleep 1
  done

  return 1
}

backend_state() {
  local name="$1"
  local socket json
  socket="$(socket_path "$name")"

  [[ -S "$socket" ]] || {
    printf '-'
    return 0
  }
  [[ -x "$TAILSCALE_BIN" ]] || {
    printf '-'
    return 0
  }

  json="$(run_with_timeout "$STATUS_TIMEOUT" "$TAILSCALE_BIN" --socket="$socket" status --json 2>/dev/null || true)"
  sed -n 's/.*"BackendState":[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$json" | head -n 1
}

wait_for_running() {
  local name="$1"
  local i state

  for ((i = 0; i < UP_TIMEOUT; i++)); do
    state="$(backend_state "$name")"
    [[ "$state" == "Running" ]] && return 0
    sleep 1
  done

  return 1
}

require_running() {
  local name="$1"
  local state

  if wait_for_running "$name"; then
    return 0
  fi

  state="$(backend_state "$name")"
  die "net '$name' did not reach Running state; current state: ${state:-unknown}"
}

wait_for_peer() {
  local name="$1"
  local host="$2"
  local socket

  [[ "$PEER_PING" == "0" ]] && return 0

  socket="$(socket_path "$name")"
  run_with_timeout "$PEER_TIMEOUT" "$TAILSCALE_BIN" --socket="$socket" ping \
    --c=1 --timeout=2s --until-direct=false "$host" >/dev/null
}

reconnect_recent() {
  local name="$1"
  local stamp_file stamp now

  [[ "$RECONNECT_COOLDOWN" == "0" ]] && return 1
  stamp_file="$(reconnect_stamp_path "$name")"
  [[ -f "$stamp_file" ]] || return 1
  read -r stamp <"$stamp_file" || return 1
  [[ "$stamp" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  ((now - stamp < RECONNECT_COOLDOWN))
}

mark_reconnect() {
  local name="$1"

  date +%s >"$(reconnect_stamp_path "$name")"
}

prune_duplicate_runtimes() {
  local name="$1"
  local keep_pid runtime_pid pid
  local seen_keep=0
  local killed=0

  keep_pid="$(tmux_child_pid "$name" 2>/dev/null || true)"
  if [[ -z "$keep_pid" ]] && pid="$(read_pid "$name" 2>/dev/null)"; then
    keep_pid="$pid"
  fi

  while read -r runtime_pid; do
    [[ -n "$runtime_pid" ]] || continue
    if [[ -z "$keep_pid" ]]; then
      keep_pid="$runtime_pid"
      seen_keep=1
      continue
    fi
    if [[ -n "$keep_pid" && "$runtime_pid" == "$keep_pid" && "$seen_keep" == "0" ]]; then
      seen_keep=1
      continue
    fi
    kill "$runtime_pid" >/dev/null 2>&1 || true
    killed=1
  done < <(managed_daemon_pids "$name")

  while read -r runtime_pid; do
    [[ -n "$runtime_pid" ]] || continue
    kill "$runtime_pid" >/dev/null 2>&1 || true
    killed=1
  done < <(legacy_daemon_pids "$name")

  [[ "$killed" == "1" ]]
}

cleanup_runtime() {
  local name="$1"
  local pid
  local runtime_pid
  local socket

  if is_tmux_running "$name"; then
    "$TMUX_BIN" kill-session -t "$(session_name "$name")" >/dev/null 2>&1 || true
  fi

  if pid="$(read_pid "$name" 2>/dev/null)"; then
    kill "$pid" >/dev/null 2>&1 || true
  fi

  socket="$(socket_path "$name")"
  while read -r runtime_pid; do
    [[ -n "$runtime_pid" ]] || continue
    kill "$runtime_pid" >/dev/null 2>&1 || true
  done < <(managed_daemon_pids "$name")

  rm -f "$(pid_path "$name")"
  rm -f "$socket"
}

recover_runtime() {
  local name="$1"

  cleanup_runtime "$name"
  start_net "$name" >/dev/null
}

ensure_daemon() {
  local name="$1"
  local attempt

  for ((attempt = 1; attempt <= RECOVER_RETRIES; attempt++)); do
    start_net "$name" >/dev/null
    prune_duplicate_runtimes "$name" || true
    if socket_responding "$name"; then
      return 0
    fi

    cleanup_runtime "$name"
    sleep 1
  done

  start_net "$name" >/dev/null
  prune_duplicate_runtimes "$name" || true
  socket_responding "$name"
}

ensure_up() {
  local name="$1"
  local attempt socket state

  for ((attempt = 1; attempt <= RECOVER_RETRIES; attempt++)); do
    if ensure_daemon "$name"; then
      socket="$(socket_path "$name")"
      if run_with_timeout "$UP_TIMEOUT" "$TAILSCALE_BIN" --socket="$socket" up 1>&2 \
        && wait_for_running "$name"; then
        return 0
      fi
    fi

    state="$(backend_state "$name")"
    printf 'net %s did not become ready (state: %s); restarting daemon (%s/%s)\n' \
      "$name" "${state:-unknown}" "$attempt" "$RECOVER_RETRIES" >&2
    cleanup_runtime "$name"
    sleep 1
  done

  recover_runtime "$name"
  socket="$(socket_path "$name")"
  run_with_timeout "$UP_TIMEOUT" "$TAILSCALE_BIN" --socket="$socket" up 1>&2
  require_running "$name"
}

ensure_ssh_ready() {
  local name="$1"
  local host="$2"

  ensure_up "$name"
  if prune_duplicate_runtimes "$name"; then
    printf 'removed duplicate tailscaled process(es) for net %s\n' "$name" >&2
  fi

  wait_for_peer "$name" "$host" 1>&2 && return 0

  if reconnect_recent "$name"; then
    printf 'warning: peer %s did not answer Tailscale ping within %ss; recent restart already attempted, trying tcp dial\n' \
      "$host" "$PEER_TIMEOUT" >&2
    return 0
  fi

  printf 'peer %s did not answer Tailscale ping within %ss; restarting net %s once before ssh dial\n' \
    "$host" "$PEER_TIMEOUT" "$name" >&2
  mark_reconnect "$name"
  cleanup_runtime "$name"
  ensure_up "$name"
  prune_duplicate_runtimes "$name" || true

  wait_for_peer "$name" "$host" 1>&2 || {
    printf 'warning: peer %s still did not answer Tailscale ping; trying tcp dial anyway\n' "$host" >&2
  }
}

start_net() {
  local name="$1"
  local dir state socket log session cmd pid proxy_listen
  local daemon_args=()
  local arg

  validate_name "$name"
  ensure_tools

  dir="$(net_dir "$name")"
  state="$(state_path "$name")"
  socket="$(socket_path "$name")"
  log="$(log_path "$name")"
  session="$(session_name "$name")"

  mkdir -p "$dir"

  if socket_responding "$name"; then
    prune_duplicate_runtimes "$name" || true
    printf 'net %s already running\n' "$name"
    return 0
  fi

  if has_tracked_runtime "$name" || [[ -S "$socket" ]]; then
    printf 'recovering stale runtime for net %s\n' "$name" >&2
    cleanup_runtime "$name"
  fi

  rm -f "$socket"
  rm -f "$(pid_path "$name")"
  : >"$log"

  daemon_args=("--tun=userspace-networking" "--state=$state" "--socket=$socket")
  proxy_listen="$(configured_proxy_listen "$name" || true)"
  if [[ -n "$proxy_listen" ]]; then
    daemon_args+=("--socks5-server=$proxy_listen" "--outbound-http-proxy-listen=$proxy_listen")
  fi

  if has_tmux; then
    cmd="$(quote_arg "$TAILSCALED_BIN")"
    for arg in "${daemon_args[@]}"; do
      cmd+=" $(quote_arg "$arg")"
    done
    cmd+=" >>$(quote_arg "$log") 2>&1"
    "$TMUX_BIN" new-session -d -s "$session" "$cmd"
    printf 'started net %s in tmux session %s\n' "$name" "$session"
  else
    nohup "$TAILSCALED_BIN" "${daemon_args[@]}" >>"$log" 2>&1 &
    pid="$!"
    printf '%s\n' "$pid" >"$(pid_path "$name")"
    printf 'started net %s as background process %s\n' "$name" "$pid"
  fi

  if ! wait_for_socket "$name"; then
    cleanup_runtime "$name" >/dev/null 2>&1 || true
    die "tailscaled did not create $socket; see $log"
  fi

  if [[ -n "$proxy_listen" ]]; then
    printf 'proxy for net %s listening at %s (SOCKS5 and HTTP CONNECT)\n' "$name" "$proxy_listen"
  fi
}

start_net_locked() {
  with_net_lock "$1" start "$1"
}

up_net() {
  local name="$1"
  shift || true

  validate_name "$name"
  with_net_lock "$name" up "$name" "$@"
}

up_net_locked() {
  local name="$1"
  shift || true

  ensure_daemon "$name" || die "failed to start net '$name'"
  run_with_timeout "$UP_TIMEOUT" "$TAILSCALE_BIN" --socket="$(socket_path "$name")" up "$@"
}

create_net() {
  local name="$1"
  shift || true

  validate_name "$name"

  if [[ -e "$(state_path "$name")" ]]; then
    die "managed net '$name' already has state; use 'up $name' or choose a new name"
  fi

  start_net "$name"
  printf 'starting login for net %s\n' "$name"
  "$TAILSCALE_BIN" --socket="$(socket_path "$name")" up "$@"
}

list_nets() {
  local dir name daemon state socket backend pid
  shopt -s nullglob

  printf '%-24s %-9s %-14s %s\n' 'NAME' 'DAEMON' 'STATE' 'SOCKET'
  [[ -d "$BASE_DIR" ]] || return 0

  for dir in "$BASE_DIR"/*; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    socket="$(socket_path "$name")"

    if socket_responding "$name" && is_tmux_running "$name"; then
      daemon='tmux'
      backend="$(backend_state "$name")"
      state="${backend:-unknown}"
    elif socket_responding "$name" && is_pid_running "$name"; then
      pid="$(read_pid "$name")"
      daemon="pid:$pid"
      backend="$(backend_state "$name")"
      state="${backend:-unknown}"
    elif socket_responding "$name"; then
      daemon='socket'
      backend="$(backend_state "$name")"
      state="${backend:-unknown}"
    elif [[ -e "$(state_path "$name")" ]]; then
      daemon='stopped'
      state='saved'
    else
      daemon='stopped'
      state='empty'
    fi

    printf '%-24s %-9s %-14s %s\n' "$name" "$daemon" "$state" "$socket"
  done
}

status_net() {
  local name="$1"
  validate_name "$name"
  ensure_tools

  [[ -d "$(net_dir "$name")" ]] || die "unknown managed net: $name"
  with_net_lock "$name" status "$name"
}

status_net_locked() {
  local name="$1"

  ensure_daemon "$name" || die "failed to start net '$name'"
  run_with_timeout "$STATUS_TIMEOUT" "$TAILSCALE_BIN" --socket="$(socket_path "$name")" status
}

proxy_net() {
  local name="$1"
  local listen_addr="${2:-127.0.0.1:1055}"

  validate_name "$name"
  validate_listen_addr "$listen_addr"
  with_net_lock "$name" proxy "$name" "$listen_addr"
}

proxy_net_locked() {
  local name="$1"
  local listen_addr="$2"

  mkdir -p "$(net_dir "$name")"
  printf '%s\n' "$listen_addr" >"$(proxy_listen_path "$name")"

  if is_running "$name"; then
    cleanup_runtime "$name"
  fi

  start_net "$name"
  printf 'SOCKS5 proxy: %s\n' "$listen_addr"
  printf 'HTTP proxy:   %s\n' "$listen_addr"
}

proxycommand_net() {
  local name="$1"
  local script

  validate_name "$name"
  script="$(script_path)"
  [[ -n "$script" ]] || die "could not resolve script path"

  printf 'ProxyCommand %s nc %s %%h %%p\n' "$(quote_arg "$script")" "$(quote_arg "$name")"
}

nc_net() {
  local name="$1"
  local host="$2"
  local port="$3"
  local socket

  validate_name "$name"
  [[ -n "$host" ]] || die "host is required"
  [[ "$port" =~ ^[0-9]+$ ]] || die "port must be numeric"
  with_net_lock "$name" ssh-ready "$name" "$host"
  socket="$(socket_path "$name")"

  # SSH ProxyCommand uses stdout as the encrypted SSH stream. Keep startup and
  # login messages on stderr so they cannot corrupt the proxied connection.
  if [[ "$NC_TIMEOUT" != "0" ]] && command -v perl >/dev/null 2>&1; then
    exec perl -e '
      $t = shift @ARGV;
      if ($t <= 0) {
        exec @ARGV or die "exec: $!\n";
      }
      $pid = fork();
      die "fork: $!\n" unless defined $pid;
      if ($pid == 0) {
        exec @ARGV or die "exec: $!\n";
      }
      $timed_out = 0;
      local $SIG{ALRM} = sub {
        $timed_out = 1;
        kill "TERM", $pid;
        select undef, undef, undef, 0.2;
        kill "KILL", $pid;
      };
      alarm $t;
      waitpid($pid, 0);
      $status = $?;
      alarm 0;
      exit 124 if $timed_out;
      exit 128 + ($status & 127) if $status & 127;
      exit($status >> 8);
    ' "$NC_TIMEOUT" "$TAILSCALE_BIN" --socket="$socket" nc "$host" "$port"
  fi

  exec "$TAILSCALE_BIN" --socket="$socket" nc "$host" "$port"
}

stop_net() {
  local name="$1"
  validate_name "$name"
  with_net_lock "$name" stop "$name"
}

stop_net_locked() {
  local name="$1"

  if is_tmux_running "$name"; then
    cleanup_runtime "$name"
    printf 'stopped net %s\n' "$name"
  elif is_pid_running "$name"; then
    cleanup_runtime "$name"
    printf 'stopped net %s\n' "$name"
  elif socket_responding "$name"; then
    "$TAILSCALE_BIN" --socket="$(socket_path "$name")" down >/dev/null 2>&1 || true
    cleanup_runtime "$name"
    printf 'stopped net %s\n' "$name"
  else
    rm -f "$(pid_path "$name")"
    rm -f "$(socket_path "$name")"
    printf 'net %s is not running\n' "$name"
  fi
}

logs_net() {
  local name="$1"
  validate_name "$name"
  [[ -e "$(log_path "$name")" ]] || die "no log exists for net '$name'"
  tail -f "$(log_path "$name")"
}

path_net() {
  local name="$1"
  validate_name "$name"
  printf 'dir:    %s\n' "$(net_dir "$name")"
  printf 'state:  %s\n' "$(state_path "$name")"
  printf 'socket: %s\n' "$(socket_path "$name")"
  printf 'log:    %s\n' "$(log_path "$name")"
  printf 'pid:    %s\n' "$(pid_path "$name")"
  printf 'proxy:  %s\n' "$(proxy_listen_path "$name")"
  printf 'lock:   %s\n' "$(lock_path "$name")"
  printf 'lockdir:%s\n' "$(lock_dir_path "$name")"
}

main() {
  local command="${1:-}"
  [[ -n "$command" ]] || {
    usage
    exit 0
  }
  shift || true

  case "$command" in
    __locked)
      [[ "$#" -ge 2 ]] || die "__locked requires NAME COMMAND"
      local locked_name="$1"
      local locked_command="$2"
      shift 2
      validate_name "$locked_name"
      case "$locked_command" in
        start)
          [[ "$#" -eq 1 && "$1" == "$locked_name" ]] || die "locked start requires NAME"
          start_net "$1"
          ;;
        up|login)
          [[ "$#" -ge 1 && "$1" == "$locked_name" ]] || die "locked up requires NAME"
          up_net_locked "$@"
          ;;
        status)
          [[ "$#" -eq 1 && "$1" == "$locked_name" ]] || die "locked status requires NAME"
          status_net_locked "$1"
          ;;
        proxy)
          [[ "$#" -eq 2 && "$1" == "$locked_name" ]] || die "locked proxy requires NAME LISTEN_ADDR"
          proxy_net_locked "$1" "$2"
          ;;
        nc)
          die "locked nc is internal and no longer supported; use ssh-ready before nc"
          ;;
        ensure-up)
          [[ "$#" -eq 1 && "$1" == "$locked_name" ]] || die "locked ensure-up requires NAME"
          ensure_up "$1"
          ;;
        ssh-ready)
          [[ "$#" -eq 2 && "$1" == "$locked_name" ]] || die "locked ssh-ready requires NAME HOST"
          ensure_ssh_ready "$1" "$2"
          ;;
        stop)
          [[ "$#" -eq 1 && "$1" == "$locked_name" ]] || die "locked stop requires NAME"
          stop_net_locked "$1"
          ;;
        *)
          die "unknown locked command: $locked_command"
          ;;
      esac
      ;;
    list)
      [[ "$#" -eq 0 ]] || die "list does not accept arguments"
      list_nets
      ;;
    create)
      [[ "$#" -ge 1 ]] || die "create requires NAME"
      create_net "$@"
      ;;
    start)
      [[ "$#" -eq 1 ]] || die "start requires NAME"
      start_net_locked "$1"
      ;;
    up|login)
      [[ "$#" -ge 1 ]] || die "$command requires NAME"
      up_net "$@"
      ;;
    status)
      [[ "$#" -eq 1 ]] || die "status requires NAME"
      status_net "$1"
      ;;
    proxy)
      [[ "$#" -ge 1 && "$#" -le 2 ]] || die "proxy requires NAME and optional LISTEN_ADDR"
      proxy_net "$@"
      ;;
    proxycommand)
      [[ "$#" -eq 1 ]] || die "proxycommand requires NAME"
      proxycommand_net "$1"
      ;;
    nc)
      [[ "$#" -eq 3 ]] || die "nc requires NAME HOST PORT"
      nc_net "$1" "$2" "$3"
      ;;
    stop)
      [[ "$#" -eq 1 ]] || die "stop requires NAME"
      stop_net "$1"
      ;;
    logs)
      [[ "$#" -eq 1 ]] || die "logs requires NAME"
      logs_net "$1"
      ;;
    path)
      [[ "$#" -eq 1 ]] || die "path requires NAME"
      path_net "$1"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
