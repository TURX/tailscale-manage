#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="${TAILSCALE_BIN_DIR:-$HOME/bin}"
TRACK="${TAILSCALE_TRACK:-stable}"
VERSION="${TAILSCALE_VERSION:-latest}"

usage() {
  cat <<'USAGE'
Download/install tailscale and tailscaled into ~/bin.

Usage:
  install-tailscale-bins.sh

Environment:
  TAILSCALE_BIN_DIR  Install directory. Default: ~/bin
  TAILSCALE_TRACK    Package track for Linux static tarballs. Default: stable
  TAILSCALE_VERSION  Linux version, or latest. Default: latest

Notes:
  - Linux downloads the official static tarball from pkgs.tailscale.com.
  - macOS arm64 uses Homebrew's tailscale bottle, then copies the CLI binaries
    into TAILSCALE_BIN_DIR.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

install_from_linux_tarball() {
  local machine arch url tmp_dir archive extracted

  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)
      arch="amd64"
      ;;
    aarch64|arm64)
      arch="arm64"
      ;;
    armv6l|armv7l)
      arch="arm"
      ;;
    i386|i686)
      arch="386"
      ;;
    *)
      die "unsupported Linux architecture: $machine"
      ;;
  esac

  need_command curl
  need_command tar

  if [[ "$VERSION" == "latest" ]]; then
    url="https://pkgs.tailscale.com/${TRACK}/tailscale_latest_${arch}.tgz"
  else
    url="https://pkgs.tailscale.com/${TRACK}/tailscale_${VERSION}_${arch}.tgz"
  fi

  tmp_dir="$(mktemp -d)"
  archive="$tmp_dir/tailscale.tgz"

  printf 'downloading %s\n' "$url"
  curl -fsSL "$url" -o "$archive"
  tar -xzf "$archive" -C "$tmp_dir"

  extracted="$(find "$tmp_dir" -maxdepth 1 -type d -name 'tailscale_*' -print -quit)"
  [[ -n "$extracted" ]] || die "could not find extracted tailscale directory"

  mkdir -p "$BIN_DIR"
  cp "$extracted/tailscale" "$extracted/tailscaled" "$BIN_DIR/"
  chmod +x "$BIN_DIR/tailscale" "$BIN_DIR/tailscaled"

  rm -rf "$tmp_dir"
}

install_from_homebrew_macos_arm64() {
  local prefix

  [[ "$(uname -m)" == "arm64" ]] || die "this macOS installer path only supports arm64"
  need_command brew

  brew install tailscale
  prefix="$(brew --prefix tailscale)"

  [[ -x "$prefix/bin/tailscale" ]] || die "tailscale not found in Homebrew prefix: $prefix"
  [[ -x "$prefix/bin/tailscaled" ]] || die "tailscaled not found in Homebrew prefix: $prefix"

  mkdir -p "$BIN_DIR"
  cp "$prefix/bin/tailscale" "$prefix/bin/tailscaled" "$BIN_DIR/"
  chmod +x "$BIN_DIR/tailscale" "$BIN_DIR/tailscaled"
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    "")
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac

  case "$(uname -s)" in
    Linux)
      install_from_linux_tarball
      ;;
    Darwin)
      install_from_homebrew_macos_arm64
      ;;
    *)
      die "unsupported OS: $(uname -s)"
      ;;
  esac

  printf 'installed tailscale binaries:\n'
  "$BIN_DIR/tailscale" version
  "$BIN_DIR/tailscaled" --version
}

main "$@"
