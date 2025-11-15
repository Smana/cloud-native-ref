# PEV2 - PostgreSQL Explain Visualizer 2

Container image for [PEV2](https://github.com/dalibo/pev2) - a standalone PostgreSQL query execution plan visualizer.

## Overview

- **Version**: PEV2 v1.17.0 (downloaded during build from GitHub releases)
- **Type**: Standalone static application (single HTML file, no backend/database)
- **Base Image**: `nginx:alpine`
- **Web Server**: nginx (non-root, port 8080)
- **Size**: ~10MB (nginx:alpine + 1.2MB pev2.html)

## Building the Image

### Prerequisites

- Docker or Podman
- Push access to container registry (ghcr.io, Docker Hub, etc.)

### Build and Push

```bash
# Navigate to this directory
cd container-images/pev2

# Build the image
./build.sh

# Push to registry
docker push ghcr.io/smana/pev2:v1.17.0
docker push ghcr.io/smana/pev2:latest
```

### Manual Build (Alternative)

```bash
# Build for specific platform
docker build --platform linux/amd64 \
  -t ghcr.io/smana/pev2:v1.17.0 \
  -t ghcr.io/smana/pev2:latest \
  .

# Build with custom PEV2 version
docker build --platform linux/amd64 \
  --build-arg PEV2_VERSION=v1.18.0 \
  -t ghcr.io/smana/pev2:v1.18.0 \
  .

# Test locally
docker run --rm -p 8080:8080 ghcr.io/smana/pev2:v1.17.0

# Open http://localhost:8080
```

## Container Details

### Security Features

- ✅ **Non-root user**: Runs as `nginx` (UID 101)
- ✅ **Read-only filesystem**: Root filesystem is immutable
- ✅ **Minimal base**: Alpine Linux (~5MB)
- ✅ **No privileges**: All capabilities dropped
- ✅ **Health checks**: Built-in `/health` endpoint

### Ports

- **8080**: HTTP (nginx, non-privileged port)

### Volumes

The container uses `emptyDir` volumes for nginx runtime:
- `/var/cache/nginx` - nginx cache directory
- `/run/nginx` - nginx PID and temporary files

No persistent storage required (stateless application).

### Health Check

Built-in Docker HEALTHCHECK:
```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1
```

## Files

```
container-images/pev2/
├── README.md           # This file
├── Dockerfile          # Container build with PEV2 download from GitHub
├── nginx.conf          # nginx configuration (port 8080, non-root)
├── build.sh           # Automated build script
└── .dockerignore      # Build optimization
```

**Note**: `pev2.html` is downloaded during Docker build from GitHub releases, not committed to the repo.

## Deployment

This container is deployed using the **App Composition** at `tooling/base/pev2/app.yaml`.

The App composition automatically creates:
- Deployment (security-hardened, HPA-managed)
- Service (ClusterIP)
- HorizontalPodAutoscaler (1-3 replicas)
- HTTPRoute (Tailscale Gateway, private access)
- CiliumNetworkPolicy (ingress from Gateway only)
- ServiceMonitor (VictoriaMetrics integration)
- PodDisruptionBudget

**Deployment location**: `tooling/base/pev2/app.yaml`

## Updating PEV2

To update to a newer version of PEV2:

```bash
# 1. Update version in Dockerfile
sed -i 's/ARG PEV2_VERSION=v1.17.0/ARG PEV2_VERSION=v1.XX.0/' Dockerfile

# 2. Update version in build.sh
sed -i 's/VERSION="v1.17.0"/VERSION="v1.XX.0"/' build.sh

# 3. Rebuild and push (PEV2 will be downloaded during build)
./build.sh
docker push ghcr.io/smana/pev2:v1.XX.0
docker push ghcr.io/smana/pev2:latest

# 4. Update App manifest
# Edit tooling/base/pev2/app.yaml
# Change spec.image.tag to "v1.XX.0"

# 5. Commit and push
git add Dockerfile build.sh tooling/base/pev2/app.yaml
git commit -m "chore(pev2): update to v1.XX.0"
git push
```

Flux will automatically deploy the update.

**Note**: The build requires internet access to download pev2.html from GitHub releases.

## Customization

### Theme/Branding

To customize PEV2's appearance:

1. Extract and modify CSS from `pev2.html`
2. Create `custom.css` with overrides
3. Mount as ConfigMap in the App manifest
4. Update nginx config to serve custom CSS

### Example Custom CSS

```css
/* Override Bootstrap theme */
:root {
  --bs-primary: #your-brand-color;
}

/* Custom header */
.navbar-brand::before {
  content: "Your Company - ";
}
```

## Architecture

```
┌─────────────────────────────────────────┐
│  nginx:alpine (UID 101, non-root)       │
│  ├─ /etc/nginx/nginx.conf               │
│  └─ /usr/share/nginx/html/              │
│     └─ index.html (pev2.html)           │
├─────────────────────────────────────────┤
│  Writable Volumes (emptyDir)            │
│  ├─ /var/cache/nginx  (50Mi)            │
│  └─ /run/nginx        (10Mi)            │
└─────────────────────────────────────────┘
```

## Resources

- **PEV2 Repository**: https://github.com/dalibo/pev2
- **PEV2 Releases**: https://github.com/dalibo/pev2/releases
- **Dalibo EXPLAIN**: https://explain.dalibo.com
- **Deployment Docs**: See `tooling/base/pev2/app.yaml`

## Troubleshooting

### Container won't start

```bash
# Check logs
docker logs <container-id>

# Common issues:
# - Permission denied: Check user is nginx (101)
# - Port already in use: Use different port (-p 8081:8080)
```

### Health check failing

```bash
# Test health endpoint
curl http://localhost:8080/health

# Should return: healthy
```

### Build fails

```bash
# Clean build cache
docker system prune -a

# Rebuild without cache
docker build --no-cache -t ghcr.io/smana/pev2:v1.17.0 .
```

## License

PEV2 is licensed under the PostgreSQL License.
See: https://github.com/dalibo/pev2/blob/main/LICENSE
