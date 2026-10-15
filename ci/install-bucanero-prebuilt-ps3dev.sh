#!/usr/bin/env bash
# Install Bucanero/ps3dev's pinned precompiled Linux x86-64 SDK bundle.
# The archive is verified before extraction; an existing destination is never overwritten.
set -Eeuo pipefail

readonly DEFAULT_RELEASE_TAG="nightly-2026-10-12"
readonly DEFAULT_ASSET_NAME="ps3dev-linux-X64.tar.gz"
readonly DEFAULT_SHA256="76b1b3bc9ac260a4ece86da520225da7f2f4e334174e37b850093ff925eeb900"

release_tag="${PS3DEV_RELEASE_TAG:-$DEFAULT_RELEASE_TAG}"
asset_name="${PS3DEV_ASSET_NAME:-$DEFAULT_ASSET_NAME}"
expected_sha256="${PS3DEV_ARCHIVE_SHA256:-$DEFAULT_SHA256}"
destination="${1:-${PS3DEV_ROOT:-"$PWD/.ps3dev-prebuilt"}}"
download_url="https://github.com/ps3dev/ps3dev/releases/download/$release_tag/$asset_name"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

case "$(uname -s)" in
    Linux) ;;
    *) fail "This pinned bundle is for Linux x86-64; host is $(uname -s)." ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) ;;
    *) fail "This pinned bundle is for x86-64; host architecture is $(uname -m)." ;;
esac

for dependency in curl sha256sum tar; do
    command -v "$dependency" >/dev/null 2>&1 || fail "Missing required command: $dependency"
done

[[ ! -e "$destination" ]] || fail "Destination already exists; refusing to overwrite it: $destination"

temporary_directory="$(mktemp -d)"
cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

archive="$temporary_directory/$asset_name"
extract_directory="$temporary_directory/extracted"
mkdir -p "$extract_directory"

printf 'Downloading %s\n' "$download_url"
curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 \
    --output "$archive" "$download_url"

printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum --check -

# The upstream release workflow packages the install tree as ps3dev/.
tar -tzf "$archive" | awk '
    $0 !~ /^ps3dev\// { bad = 1; print "Unexpected archive path: " $0 > "/dev/stderr" }
    END { if (bad || NR == 0) exit 1 }
' || fail "The archive layout is not the expected ps3dev/ tree."

tar -xzf "$archive" -C "$extract_directory"
source_directory="$extract_directory/ps3dev"

for required in ppu/bin/ppu-gcc spu/bin/spu-gcc ppu_rules base_rules; do
    [[ -e "$source_directory/$required" ]] || fail "SDK archive is missing: $required"
done

mkdir -p "$(dirname "$destination")"
mv "$source_directory" "$destination"

printf '\nPrecompiled PS3DEV/PSL1GHT installed successfully.\n'
printf '  Release: %s\n' "$release_tag"
printf '  Path:    %s\n' "$destination"
printf '  SHA256:  %s\n' "$expected_sha256"
