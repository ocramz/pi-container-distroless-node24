#!/usr/bin/env bash
# Integration test driver.
#
#   IMAGE=... tests/run.sh              run every test_*.sh
#   IMAGE=... tests/run.sh test_pi_cli.sh   run specific ones
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1

: "${IMAGE:?IMAGE must be set (e.g. make test)}"
export ENGINE="${ENGINE:-podman}"
export IMAGE
export PI_VERSION="${PI_VERSION:-}"

# Kept compatible with bash 3.2: macOS still ships it as /bin/bash, and this
# harness has to run there as well as on CI.
if [ $# -eq 0 ]; then
	set -- test_*.sh
fi

echo "image:  $IMAGE"
echo "engine: $ENGINE"
echo

failed=""
for t in "$@"; do
	printf '\033[1m%s\033[0m\n' "$t"
	if ! bash "$HERE/$t"; then
		failed="$failed $t"
	fi
	echo
done

if [ -n "$failed" ]; then
	printf '\033[31mFAILED:%s\033[0m\n' "$failed"
	exit 1
fi
printf '\033[32mall suites passed\033[0m\n'
