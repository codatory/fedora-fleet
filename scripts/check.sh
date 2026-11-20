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

tmpfiles=$(mktemp)
trap 'rm -f "$tmpfiles"' EXIT

# Manifests are Tera-templated before they are parsed, so ordinary YAML tools reject them.
# The structural checks below are therefore line-based, and comtrya is the real parser.
#
# `files/` beside a manifest holds data for `file.copy`/`file.link`, never manifests, so
# comtrya does not read it and neither should this. `.yml` is a manifest extension to
# comtrya, so it is linted like `.yaml`.
find manifests \( -name '*.yaml' -o -name '*.yml' \) | grep -v '/files/' | sort >"$tmpfiles"
while IFS= read -r file; do
	grep -q 'yaml-language-server: \$schema=https://comtrya.dev/schema.json' "$file" ||
		fail "$file" "missing the schema comment"
	grep -qx 'version: 1' "$file" ||
		fail "$file" "missing 'version: 1'"
done <"$tmpfiles"

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
# the step reports success. Any shell counts: `bash -c` fails the same way `sh -c` does.
for file in $(grep -rlE 'command: *(sh|bash)$' manifests || true); do
	grep -q 'set -eu' "$file" ||
		fail "$file" "runs a shell without 'set -eu'"
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
