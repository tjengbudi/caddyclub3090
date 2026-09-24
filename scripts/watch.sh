#!/usr/bin/env bash
# Entrypoint of the router container: keep :80 pointed at the live engine.
#
# Reacts to docker container start/die/stop events. Every event is followed by
# a short settle delay before reconciling — engines publish their port before
# they answer, and reconcile.sh is a no-op when nothing actually changed, so a
# burst of events costs almost nothing.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/lib-discover.sh"

RECONCILE="${ROOT}/scripts/reconcile.sh"
SETTLE=2

log() { echo "[watch] $*" >&2; }

# Caddy has to be listening on the admin port before any config can be pushed.
for _ in $(seq 1 60); do
	curl -s -o /dev/null --max-time 2 http://127.0.0.1:2019/config/ && break
	sleep 1
done

log "starting"

# reconcile.sh's retry lock dies with the process that held it; one left over
# from a previous container would block the booting-backend retry for good.
rmdir "${ROOT}/state/.retry.lock" 2>/dev/null

# Without the docker socket, discovery sees no engines and :80 sits on a 503
# forever. Say why, instead of looping on a bare "event stream ended".
if ! docker version >/dev/null 2>&1; then
	log "ERROR: cannot talk to the docker daemon as $(id -u):$(id -g)" \
		"(socket group is $(stat -c %g /var/run/docker.sock 2>/dev/null || echo '?'))." \
		"Is the socket mounted, and did the container start via router-entry.sh?"
fi

bash "$RECONCILE"

# Heartbeat: docker events cover engines coming and going, but not Caddy
# itself restarting. A reconcile every minute is a couple of curls when
# nothing changed, and it puts an upper bound on how long a restarted Caddy
# can sit on its bootstrap config.
(
	while true; do
		sleep 60
		bash "$RECONCILE" >/dev/null 2>&1
	done
) &

while true; do
	docker events \
		--filter type=container \
		--filter event=start --filter event=die --filter event=stop \
		--format '{{.Actor.Attributes.name}}' \
	| while read -r name; do
		[[ "$name" =~ $C3_ENGINE_RE ]] || continue
		log "event: ${name}"
		sleep "$SETTLE"
		bash "$RECONCILE"
	done
	# docker events only returns if the daemon went away or the stream broke.
	log "event stream ended; retrying in 5s"
	sleep 5
done
