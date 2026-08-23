# Build Caddy with the model_alias module. Done inside Docker so the host
# needs no Go toolchain.
FROM caddy:2-builder AS builder

COPY modelalias/ /src/modelalias/
# go mod tidy resolves the Caddy version from the imports, so the module's
# go.mod never has to pin one by hand.
RUN cd /src/modelalias && go mod tidy
RUN xcaddy build --with github.com/tjengbudi/caddyclub3090/modelalias=/src/modelalias

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
