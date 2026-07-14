# syntax=docker/dockerfile:1
# App Wizard — single Go binary serving the embedded React SPA (SPEC-008).
#
# Stage 1: build the SPA into internal/web/dist.
# Stage 2: build the Go binary embedding that dist via go:embed.
# Stage 3: distroless runtime, non-root.

ARG APP_WIZARD_VERSION=v0.1.0

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

# ---------- Runtime ----------
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=build /out/app-wizard /app-wizard
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app-wizard"]
