#!/bin/sh
# Install lantern on Linux from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/jetcuhh/lantern/main/install.sh | sh
#
# Environment:
#   LANTERN_VERSION      version to install, e.g. 0.2.0 (default: latest)
#   LANTERN_INSTALL_DIR  where to put the binary (default: /usr/local/bin as
#                        root, otherwise ~/.local/bin)

set -eu

repo=jetcuhh/lantern
releases="https://github.com/$repo/releases"

say() { printf 'lantern: %s\n' "$*"; }
die() { printf 'lantern: %s\n' "$*" >&2; exit 1; }

# --- platform ---------------------------------------------------------------

[ "$(uname -s)" = Linux ] || die "only Linux is supported"

machine=$(uname -m)
case "$machine" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "unsupported architecture: $machine" ;;
esac

libc=gnu
if ldd --version 2>&1 | grep -qi musl; then
    libc=musl
elif ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
    libc=musl
fi

asset="lantern-$arch-linux-$libc"

# --- download ---------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
else
    die "curl or wget is required"
fi

if [ -n "${LANTERN_VERSION:-}" ]; then
    version=${LANTERN_VERSION#v}
    url="$releases/download/v$version"
else
    version=latest
    url="$releases/latest/download"
fi

tmp=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "downloading $asset ($version)"
fetch "$url/$asset" "$tmp/$asset" || die "no release asset named $asset"

if command -v sha256sum >/dev/null 2>&1 && fetch "$url/SHA256SUMS" "$tmp/SHA256SUMS" 2>/dev/null; then
    expected=$(awk -v name="$asset" '$2 == name { print $1 }' "$tmp/SHA256SUMS")
    actual=$(sha256sum "$tmp/$asset" | awk '{ print $1 }')
    [ -n "$expected" ] || die "$asset is not listed in SHA256SUMS"
    [ "$actual" = "$expected" ] || die "checksum mismatch for $asset"
    say "checksum ok"
else
    say "warning: could not verify the checksum"
fi

# --- install ----------------------------------------------------------------

if [ -n "${LANTERN_INSTALL_DIR:-}" ]; then
    dest=$LANTERN_INSTALL_DIR
elif [ "$(id -u)" -eq 0 ]; then
    dest=/usr/local/bin
else
    [ -n "${HOME:-}" ] || die "HOME is not set; set LANTERN_INSTALL_DIR"
    dest=$HOME/.local/bin
fi

mkdir -p "$dest" || die "cannot create $dest"
install -m 0755 "$tmp/$asset" "$dest/lantern" || die "cannot write $dest/lantern"

"$dest/lantern" version >/dev/null 2>&1 || say "warning: $dest/lantern did not run"
say "installed $asset to $dest/lantern"

case ":$PATH:" in
    *":$dest:"*) ;;
    *) say "add $dest to PATH to run it by name" ;;
esac