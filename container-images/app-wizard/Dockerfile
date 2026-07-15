# syntax=docker/dockerfile:1
# App Wizard — single Go binary serving the embedded React SPA (SPEC-008).
#
# Stage 1: build the SPA into internal/web/dist.
# Stage 2: build the Go binary embedding that dist via go:embed.
# Stage 3: fetch the crossplane CLI (the render preview shells out to it).
# Stage 4: distroless runtime, non-root.

ARG APP_WIZARD_VERSION=v0.1.0

# The render preview runs `crossplane render` as a subprocess
# (internal/render/crossplane.go: Binary defaults to "crossplane"), so the CLI has to
# be IN the image — distroless ships nothing but what we copy. Without it the preview
# fails with:
#   crossplane render failed: exec: "crossplane": executable file not found in $PATH
#
# Kept in step with the Crossplane running on the cluster (v2.3.3) so the renderer
# behaves the way the cluster will. The CLI's release artifact is named `crank`.
ARG CROSSPLANE_VERSION=v2.3.3

# ---------- UI build ----------
FROM node:22-alpine AS ui
WORKDIR /src/ui
COPY ui/package.json ui/package-lock.json* ./
RUN npm ci || npm install
COPY ui/ ./
RUN npm run build

# ---------- Go build ----------
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
# Overwrite the committed placeholder with the real SPA build output.
COPY --from=ui /src/internal/web/dist ./internal/web/dist
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/app-wizard ./cmd/app-wizard

# ---------- crossplane CLI ----------
FROM alpine:3.21 AS crossplane-cli
ARG TARGETOS
ARG TARGETARCH
ARG CROSSPLANE_VERSION
RUN apk add --no-cache curl \
    && curl -fsSL -o /out-crossplane \
       "https://releases.crossplane.io/stable/${CROSSPLANE_VERSION}/bin/${TARGETOS}_${TARGETARCH}/crank" \
    && chmod 0755 /out-crossplane \
    # Fail the build here rather than at runtime if the download silently 404s into
    # an HTML error page: a non-executable "binary" would only surface as a broken
    # preview in production.
    && /out-crossplane version --client

# ---------- Runtime ----------
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=build /out/app-wizard /app-wizard
# The renderer resolves "crossplane" through $PATH; distroless sets PATH to
# /usr/local/bin:/usr/bin:/bin, so this lands on it.
COPY --from=crossplane-cli /out-crossplane /usr/local/bin/crossplane
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app-wizard"]
