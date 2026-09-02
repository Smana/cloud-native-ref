# Build stage: compile a static binary. CGO_ENABLED=0 removes the libc
# dependency the distroless runtime below has no shell to satisfy anyway;
# -trimpath drops build-machine paths from the binary, -ldflags="-s -w"
# strips the symbol table and DWARF debug info.
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/token-exchange-proxy .

# Distroless static, not base: this proxy's only egress is HTTPS -- to the
# RFC 8693 token endpoint (TEP_STS_URL) and to TEP_UPSTREAM_URL -- so the CA
# bundle is required and nothing else is (no libc, no shell, no package
# manager). `nonroot` runs as uid/gid 65532 without a Kubernetes
# securityContext override.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/token-exchange-proxy /token-exchange-proxy
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/token-exchange-proxy"]
