#!/bin/sh

set -eu

repo=jetcuhh/lantern
prefix=${PREFIX:-$HOME/.local}
version=${VERSION:-latest}

usage() {
    cat <<'EOF'
Install the lantern binary from a GitHub release.

  install.sh [--system] [--prefix DIR] [--version VER]

  --system         install under /usr/local (needs write access)
  --prefix DIR     install under DIR instead of ~/.local
  --version VER    install a specific release instead of the latest
  -h, --help       show this help

Environment: PREFIX, VERSION.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --system) prefix=/usr/local ;;
        --prefix)
            shift
            prefix=${1:?--prefix needs a directory}
            ;;
        --version)
            shift
            version=${1:?--version needs a version}
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "install: unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

die() {
    echo "install: $*" >&2
    exit 1
}

for cmd in curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

arch=$(uname -m)
case $arch in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "unsupported architecture: $arch (release builds: x86_64, aarch64); build from source instead" ;;
esac

libc=gnu
if ldd --version 2>&1 | grep -qi musl; then
    libc=musl
elif [ -e "/lib/ld-musl-$arch.so.1" ]; then
    case $arch in
        x86_64) [ -e /lib64/ld-linux-x86-64.so.2 ] || libc=musl ;;
        aarch64) [ -e /lib/ld-linux-aarch64.so.1 ] || libc=musl ;;
    esac
fi

if [ "$version" = latest ]; then
    tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") ||
        die "cannot reach github"
    tag=${tag##*/}
else
    case $version in
        v*) tag=$version ;;
        *) tag=v$version ;;
    esac
fi
[ -n "$tag" ] || die "cannot determine which release to install"
ver=${tag#v}

name=lantern-$arch-linux-$libc
base=https://github.com/$repo/releases/download/$tag

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "downloading $name ($tag)"
curl -fsSL -o "$tmp/$name" "$base/$name" ||
    die "no $libc build of $ver for $arch; see https://github.com/$repo/releases"

if curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" 2>/dev/null &&
    command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmp" && grep -F " $name" SHA256SUMS | sha256sum -c --status -) ||
        die "checksum mismatch for $name"
fi

mkdir -p "$prefix/bin"
cp "$tmp/$name" "$prefix/bin/lantern.new.$$"
chmod 755 "$prefix/bin/lantern.new.$$"
mv -f "$prefix/bin/lantern.new.$$" "$prefix/bin/lantern"

echo
echo "installed lantern $ver ($arch, $libc) to $prefix/bin/lantern"
case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "note: $prefix/bin is not on your PATH" ;;
esac
