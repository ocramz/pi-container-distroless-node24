#!/usr/bin/env bash
# Pi itself starts, reports the version we pinned, and does not phone home.
source "$(dirname "$0")/lib.sh"

version="$(run_pi --version | tr -d '\r\n')"
if [ -n "${PI_VERSION:-}" ]; then
	assert_eq "reports the pinned version" "$PI_VERSION" "$version"
else
	assert_contains "reports a version" "." "$version"
fi

help="$(run_pi --help)"
for flag in --mode --print --no-session --extension --api-key --approve; do
	assert_contains "help documents $flag" "$flag" "$help"
done
assert_contains "package subcommands available" "pi install <source>" "$help"

# Everything below runs with no network at all. Two things could break it: the
# pi.dev version check (disabled via PI_SKIP_VERSION_CHECK) and the tools-manager
# downloading ripgrep/fd from GitHub (avoided by shipping them).
offline="$(RUN_FLAGS="--network=none" run_pi --version)"
assert_eq "starts with no network" "$version" "$(tr -d '\r\n' <<<"$offline")"

list="$(RUN_FLAGS="--network=none" run_pi list)"
assert_not_contains "pi list works offline" "ENOTFOUND" "$list"
assert_not_contains "pi list does not fetch" "getaddrinfo" "$list"

# Pi resolves rg/fd from PATH before falling back to its downloader; if that
# regressed, the agent would try to reach api.github.com on its first grep.
tools="$(in_image 'command -v rg; command -v fd; echo "downloaded=$(ls "$PI_CODING_AGENT_DIR/bin" 2>/dev/null | wc -l)"')"
assert_contains "ripgrep resolves from PATH" "/usr/bin/rg" "$tools"
assert_contains "fd resolves from PATH" "/usr/bin/fd" "$tools"
assert_contains "no downloaded tools in the agent dir" "downloaded=0" "$tools"

# The bundled extension is discoverable where Pi looks for global extensions.
ext="$(in_image 'ls "$PI_CODING_AGENT_DIR/extensions"')"
assert_contains "container-env extension is installed" "container-env.ts" "$ext"

summary
