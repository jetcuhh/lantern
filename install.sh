#!/bin/sh

set -eu

repo=jetcuhh/unn
prefix=${PREFIX:-$HOME/.local}
version=${VERSION:-latest}

usage() {
    cat <<'EOF'
Install unn from a GitHub release.

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

for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

arch=$(uname -m)
case $arch in
    x86_64 | amd64) arch=x86_64 ;;
    *) die "release builds are x86_64 only; build from source instead" ;;
esac

libc=gnu
if ldd --version 2>&1 | grep -qi musl; then
    libc=musl
elif [ -e "/lib/ld-musl-$arch.so.1" ] && [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
    libc=musl
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

name=unn-$ver-linux-$arch-$libc
base=https://github.com/$repo/releases/download/$tag

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "downloading $name"
curl -fsSL -o "$tmp/$name.tar.gz" "$base/$name.tar.gz" ||
    die "no $libc build of $ver; see https://github.com/$repo/releases"

if curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" 2>/dev/null &&
    command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmp" && grep -F " $name.tar.gz" SHA256SUMS | sha256sum -c --status -) ||
        die "checksum mismatch for $name.tar.gz"
fi

tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
src=$tmp/$name
[ -x "$src/bin/unn" ] || die "malformed archive: bin/unn is missing"

install_file() {
    mkdir -p "$(dirname "$2")"
    cp "$1" "$2.new.$$"
    chmod "$3" "$2.new.$$"
    mv -f "$2.new.$$" "$2"
}

install_file "$src/bin/unn" "$prefix/bin/unn" 755
install_file "$src/share/applications/jet.unn.desktop" \
    "$prefix/share/applications/jet.unn.desktop" 644
install_file "$src/share/icons/hicolor/scalable/apps/jet.unn.svg" \
    "$prefix/share/icons/hicolor/scalable/apps/jet.unn.svg" 644
install_file "$src/share/man/man1/unn.1" "$prefix/share/man/man1/unn.1" 644
install_file "$src/share/man/man5/unn.5" "$prefix/share/man/man5/unn.5" 644
install_file "$src/share/doc/unn/examples/50-unn.conf" \
    "$prefix/share/doc/unn/examples/50-unn.conf" 644
install_file "$src/share/terminfo/u/unn" "$prefix/share/terminfo/u/unn" 644

echo
echo "installed unn $ver ($libc) to $prefix"
