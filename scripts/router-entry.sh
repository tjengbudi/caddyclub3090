#!/usr/bin/env bash
# Router container entrypoint: starts as root only long enough to read the
# docker socket's group, then drops to uid 1000 with that group and runs the
# given command.
#
# The docker group's GID is not fixed — a docker-ce reinstall recreates the
# group with a new one — so it is read off the socket on every start instead of
# being baked into the container config. state/ files stay owned by the host
# user either way.
set -euo pipefail

SOCK=/var/run/docker.sock
RUN_UID=1000

gid=$(stat -c %g "$SOCK" 2>/dev/null || true)
if [[ -z "$gid" ]]; then
	echo "[entry] ${SOCK} is not mounted; running as ${RUN_UID}:${RUN_UID}" >&2
	gid=$RUN_UID
fi

exec su-exec "${RUN_UID}:${gid}" "$@"
