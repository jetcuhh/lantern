#!/bin/sh
# Build and publish a lantern release.
#
# The version comes from src/main.zig; the tag is v<version>. Four Linux
# binaries are built (x86_64 and aarch64, glibc and musl) and uploaded
# together with a SHA256SUMS file.

set -eu

cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
usage: scripts/release.sh [--draft]

Build the four Linux release binaries and publish tag v<version>, read from
src/main.zig. Pass --draft to create a draft release instead.
EOF
}

draft=false
for arg in "$@"; do
    case "$arg" in
        --draft) draft=true ;;
        -h | --help) usage; exit 0 ;;
        *)
            printf 'release: unknown argument: %s\n' "$arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

version=$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' src/main.zig)
[ -n "$version" ] || { echo "release: cannot read version from src/main.zig" >&2; exit 1; }
tag="v$version"

[ -z "$(git status --porcelain)" ] || { echo "release: working tree is not clean" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || { echo "release: gh is required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "release: gh is not authenticated (run 'gh auth login')" >&2; exit 1; }

zig=${ZIG:-zig}
command -v "$zig" >/dev/null 2>&1 || { echo "release: $zig is not on PATH" >&2; exit 1; }

dist=dist
rm -rf "$dist"
mkdir -p "$dist"

targets="x86_64-linux-gnu x86_64-linux-musl aarch64-linux-gnu aarch64-linux-musl"
for target in $targets; do
    arch=${target%%-linux-*}
    libc=${target##*-linux-}
    name="lantern-$arch-linux-$libc"
    printf 'release: building %s\n' "$target"
    "$zig" build \
        -Dtarget="$target" \
        -Doptimize=ReleaseFast \
        -Dstrip=true \
        --prefix "$dist/.build-$target"
    mv "$dist/.build-$target/bin/lantern" "$dist/$name"
    rm -rf "$dist/.build-$target"
done

(cd "$dist" && sha256sum lantern-* > SHA256SUMS)

if gh release view "$tag" >/dev/null 2>&1; then
    printf 'release: uploading to existing release %s\n' "$tag"
    gh release upload "$tag" "$dist"/lantern-* "$dist/SHA256SUMS" --clobber
elif [ "$draft" = true ]; then
    gh release create "$tag" "$dist"/lantern-* "$dist/SHA256SUMS" \
        --draft --title "$tag" --notes "lantern $version" \
        --target "$(git rev-parse HEAD)"
else
    gh release create "$tag" "$dist"/lantern-* "$dist/SHA256SUMS" \
        --title "$tag" --notes "lantern $version" \
        --target "$(git rev-parse HEAD)"
fi

printf 'release: published %s\n' "$tag"