#!/bin/sh
# Initializes a workstation: gets the pinned comtrya, then applies every manifest.
#
#   git clone https://github.com/<you>/fedora-fleet.git ~/Code/fedora-fleet
#   ~/Code/fedora-fleet/bootstrap.sh
#
# Add --dry-run to see what the first run would change.
#
# Installing comtrya is the manifests' job, so this only has to supply the pinned version
# once, which is what the download is for. Any arguments are passed to `comtrya apply`.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# The manifest is the only place the version is written down.
version=$(sed -n 's/.*{% set comtrya_version = "\([^"]*\)" %}.*/\1/p' \
	manifests/base/comtrya.yaml)
if [ -z "$version" ]; then
	echo "bootstrap: no comtrya_version in manifests/base/comtrya.yaml" >&2
	exit 1
fi

# A comtrya at the pinned version is enough: the manifests below find the system in sync.
if command -v comtrya >/dev/null 2>&1 &&
	[ "$(comtrya --version | awk '{print $2}')" = "${version#v}" ]; then
	exec comtrya -d manifests apply "$@"
fi

# Otherwise fetch that version with comtrya's own install script, which picks the asset for
# this CPU and verifies its SHA-256. It goes into a directory of its own and is thrown away
# afterwards, because the manifests put the real install in /usr/local.
download=$(mktemp -d)
trap 'rm -rf "$download"' EXIT

installer="$download/install.sh"
curl -fsSL https://comtrya.dev/install.sh -o "$installer"
VERSION="$version" INSTALL_DIR="$download" sh "$installer"

"$download/comtrya" -d manifests apply "$@"
