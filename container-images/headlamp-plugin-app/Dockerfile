# This ARG is what makes CI publish the tag the HelmRelease pins.
# .github/workflows/build-container-images.yml derives a version tag from
# `ARG <IMAGE_NAME_UPPERCASED>_VERSION=` in this file; with no such ARG the
# workflow only ever produces `latest` and `<branch>-<sha>`, so the pinned
# `:v0.1.0` reference in tooling/base/headlamp/helmrelease.yaml would never
# resolve and the init container would ImagePullBackOff. Keep this in step
# with VERSION in build.sh.
ARG HEADLAMP_PLUGIN_APP_VERSION=v0.1.0

# Build stage. The gates run here on purpose: this repo's container build
# workflow is the only CI that ever looks at this directory, and it runs on
# pull requests (building without pushing). A broken plugin therefore fails the
# PR rather than shipping.
FROM node:24-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run lint && npm run tsc && npm test && npm run build

# Runtime: an init container whose only job is to copy the built plugin into
# the shared plugins volume before Headlamp starts. Headlamp's chart mounts
# that volume at /build/plugins and the existing init containers all run
# `cp -r /plugins/* /build/plugins/`, so the layout below is what they expect.
FROM alpine:3
COPY --from=build /src/dist/main.js /plugins/headlamp-plugin-app/main.js
COPY --from=build /src/package.json /plugins/headlamp-plugin-app/package.json
