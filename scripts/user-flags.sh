#!/bin/sh
# Print the container-engine flags that make a bind-mounted workspace usable.
#
# The image runs as uid 65532. Files on the host belong to the invoking user, so
# without a mapping the container either cannot read them or writes files the
# host user cannot touch. The right flag depends on the engine:
#
#   rootless podman  --userns=keep-id maps 65532 back to the invoking user
#   everything else  run as the host uid directly -- this covers Docker and
#                    podman on macOS, where the podman machine is rootful and
#                    virtiofs passes host uids straight through, so keep-id has
#                    nothing to map. HOME and every state directory in the image
#                    are world-writable precisely so an unknown uid still works.
#
# Used by both the Makefile and the test harness so they cannot drift apart.
ENGINE="${ENGINE:-podman}"

if [ "$(basename "$ENGINE")" = "podman" ] &&
	[ "$("$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
	echo "--userns=keep-id:uid=65532,gid=65532"
else
	echo "--user $(id -u):$(id -g)"
fi
