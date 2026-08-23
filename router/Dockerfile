# Watcher sidecar: reacts to docker events and pushes new config to Caddy's
# admin API. Runs as uid 1000 / gid docker so the state files it writes stay
# editable by the host user.
FROM alpine:3.20
RUN apk add --no-cache bash curl docker-cli
ENTRYPOINT ["/bin/bash"]
