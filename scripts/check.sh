#!/bin/sh
# Checks the repository against the conventions in docs/adding-a-manifest.md.
#
#   ./scripts/check.sh            # parse and lint, no changes
#   ./scripts/check.sh --apply    # also plan every manifest with comtrya
#
# Idempotence is not checked here: that needs a real run followed by a second one, see
# docs/comtrya-behaviour.md.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# Every check appends to this rather than exiting, so one run reports everything.
failures=""
fail() { failures="$failures
FAIL $1: $2"; }

# Manifests are Tera-templated before they are parsed, so ordinary YAML tools reject them.
# The structural checks below are therefore line-based, and comtrya is the real parser.
for file in $(find manifests -name '*.yaml' | sort); do
	grep -q 'yaml-language-server: \$schema=https://comtrya.dev/schema.json' "$file" ||
		fail "$file" "missing the schema comment"
	grep -qx 'version: 1' "$file" ||
		fail "$file" "missing 'version: 1'"
done

# The version is defined once, and bootstrap.sh reads it from that definition.
manifest=manifests/base/comtrya.yaml
version=$(sed -n 's/.*{% set comtrya_version = "\([^"]*\)" %}.*/\1/p' "$manifest")
if [ -z "$version" ]; then
	fail "$manifest" "no comtrya_version; bootstrap.sh reads the version from here"
fi
others=$(grep -rl 'comtrya_version' manifests | grep -v "^$manifest$" || true)
if [ -n "$others" ]; then
	fail manifests "comtrya_version is used outside $manifest: $others"
fi

# A script that would abort when a command fails. Without -e the failure is swallowed and
# the step reports success.
for file in $(grep -rl 'command: sh' manifests || true); do
	grep -q 'set -eu' "$file" ||
		fail "$file" "runs sh without 'set -eu'"
done

if [ -n "$failures" ]; then
	printf '%s\n' "$failures" | tail -n +2 >&2
	exit 1
fi
printf 'lint passed (comtrya %s pinned)\n' "$version"

if [ "${1:-}" = "--apply" ]; then
	comtrya=${COMTRYA:-comtrya}
	if ! command -v "$comtrya" >/dev/null 2>&1; then
		printf 'FAIL --apply: comtrya not found; set COMTRYA=/path/to/comtrya\n' >&2
		exit 1
	fi
	# `status` loads and parses every manifest, and fails if any can't be loaded.
	"$comtrya" -d manifests status
	# `--dry-run` plans every action; one that can't be planned fails it.
	"$comtrya" -d manifests apply --dry-run
fi
