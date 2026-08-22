#!/usr/bin/env bash
# Shared helpers for the integration tests.
#
# Sourced by every tests/test_*.sh. Expects ENGINE and IMAGE in the environment
# (tests/run.sh sets them; the Makefile passes them through).
set -uo pipefail

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:?IMAGE must be set}"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Used by the sourcing test scripts.
# shellcheck disable=SC2034
FIXTURES="$TESTS_DIR/fixtures"

# Same uid mapping the Makefile's `run` target uses, so tests exercise the
# invocation we actually document.
# shellcheck disable=SC2034
USER_FLAGS="$(ENGINE="$ENGINE" "$TESTS_DIR/../scripts/user-flags.sh")"

_pass=0
_fail=0

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

ok() {
	_pass=$((_pass + 1))
	green "  ok   $1"
}

fail() {
	_fail=$((_fail + 1))
	red "  FAIL $1"
	[ $# -gt 1 ] && printf '       %s\n' "${@:2}"
	return 0
}

assert_eq() { # <label> <expected> <actual>
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected: $2" "actual:   $3"; fi
}

assert_contains() { # <label> <needle> <haystack>
	case "$3" in
	*"$2"*) ok "$1" ;;
	*) fail "$1" "expected to contain: $2" "actual: $(printf '%s' "$3" | head -c 500)" ;;
	esac
}

assert_not_contains() { # <label> <needle> <haystack>
	case "$3" in
	*"$2"*) fail "$1" "expected NOT to contain: $2" ;;
	*) ok "$1" ;;
	esac
}

assert_ok() { # <label> <exit-code>
	if [ "$2" = 0 ]; then ok "$1"; else fail "$1" "exit code $2"; fi
}

# Run a bash command inside the image. Extra engine flags via RUN_FLAGS.
in_image() { # <command...>
	# shellcheck disable=SC2086
	$ENGINE run --rm ${RUN_FLAGS:-} --entrypoint /bin/bash "$IMAGE" -c "$*" 2>&1
}

# Run the image's entrypoint (pi itself) with the given arguments.
run_pi() { # <args...>
	# shellcheck disable=SC2086
	$ENGINE run --rm ${RUN_FLAGS:-} "$IMAGE" "$@" 2>&1
}

summary() {
	echo
	if [ "$_fail" -gt 0 ]; then
		red "$(basename "$0"): $_pass passed, $_fail failed"
		exit 1
	fi
	green "$(basename "$0"): $_pass passed"
}
