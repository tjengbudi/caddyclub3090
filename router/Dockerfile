# Watcher sidecar: reacts to docker events and pushes new config to Caddy's
# admin API. scripts/router-entry.sh drops it to uid 1000 / the docker socket's
# group, so the state files it writes stay editable by the host user.
FROM alpine:3.20
RUN apk add --no-cache bash curl docker-cli su-exec
ENTRYPOINT ["/bin/bash"]
