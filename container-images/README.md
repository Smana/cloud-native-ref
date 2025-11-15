# Container Images

This directory contains Dockerfiles and build contexts for all custom container images used in the cloud-native-ref platform.

## Directory Structure

```
container-images/
├── pev2/                    # PostgreSQL Explain Visualizer 2
│   ├── Dockerfile
│   ├── nginx.conf
│   ├── pev2.html
│   ├── build.sh
│   └── README.md
└── README.md               # This file
```

## Automated Builds

Container images are **automatically built and pushed** via GitHub Actions when changes are detected.

### Workflow: `build-container-images.yml`

**Triggers:**
- ✅ Push to `main` branch (when files in `container-images/` change)
- ✅ Pull requests (builds but doesn't push)
- ✅ Manual dispatch (build specific image or all)

**Features:**
- 🔍 **Smart Change Detection**: Only builds images that have changed
- 🏗️ **Multi-arch Builds**: Supports `linux/amd64` and `linux/arm64`
- 🔒 **Security Scanning**: Trivy scans for HIGH/CRITICAL vulnerabilities
- 📦 **Automatic Tagging**: `latest`, `<sha>`, `<branch>-<sha>`
- 💾 **Build Cache**: GitHub Actions cache for faster builds
- 📊 **Build Summary**: Detailed summary in workflow run

### How It Works

1. **Change Detection**
   ```yaml
   # Workflow triggers only when these paths change:
   paths:
     - 'container-images/**'
     - '.github/workflows/build-container-images.yml'
   ```

2. **Matrix Build**
   - Detects which images changed (e.g., `pev2`)
   - Creates dynamic build matrix
   - Builds only affected images in parallel

3. **Build and Push**
   - Uses Docker Buildx for multi-platform builds
   - Pushes to `ghcr.io/<owner>/<image-name>:<tag>`
   - Runs Trivy security scan
   - Uploads SARIF to GitHub Security tab

### Example Workflow Run

```
Trigger: Push to main (modified container-images/pev2/Dockerfile)

Jobs:
├─ detect-changes
│  └─ Changed images: ["pev2"]
├─ build-and-push (matrix: pev2)
│  ├─ Build for linux/amd64, linux/arm64
│  ├─ Push to ghcr.io/smana/pev2:latest
│  ├─ Push to ghcr.io/smana/pev2:<sha>
│  └─ Run Trivy scan
└─ build-summary
   └─ Create GitHub summary with results
```

## Manual Builds

### Local Development

Each image directory contains a `build.sh` script for local builds:

```bash
cd container-images/pev2
./build.sh

# Push manually (if needed)
docker push ghcr.io/smana/pev2:v1.17.0
```

### Manual GitHub Actions Trigger

Trigger builds manually via GitHub UI or CLI:

```bash
# Build all images
gh workflow run build-container-images.yml

# Build specific image
gh workflow run build-container-images.yml -f image=pev2
```

## Adding a New Image

To add a new container image:

1. **Create directory structure**
   ```bash
   mkdir -p container-images/<image-name>
   cd container-images/<image-name>
   ```

2. **Add required files**
   ```
   container-images/<image-name>/
   ├── Dockerfile          # REQUIRED
   ├── build.sh           # Optional - local build script
   ├── .dockerignore      # Optional - build optimization
   └── README.md          # Optional - image documentation
   ```

3. **Create Dockerfile**
   Follow these best practices:
   - ✅ Use specific base image tags (not `latest`)
   - ✅ Run as non-root user
   - ✅ Use multi-stage builds
   - ✅ Minimize layers
   - ✅ Add HEALTHCHECK
   - ✅ Use Alpine variants when possible

   Example minimal Dockerfile:
   ```dockerfile
   FROM alpine:3.19
   RUN adduser -D -u 1001 appuser
   USER appuser
   COPY app /app
   HEALTHCHECK CMD /app --health
   CMD ["/app"]
   ```

4. **Test locally**
   ```bash
   docker build -t test-image .
   docker run --rm test-image
   ```

5. **Commit and push**
   ```bash
   git add container-images/<image-name>/
   git commit -m "feat(images): add <image-name> container"
   git push
   ```

6. **GitHub Actions will automatically**:
   - Detect the new image
   - Build for amd64 + arm64
   - Push to ghcr.io
   - Run security scan

## Image Registry

All images are published to **GitHub Container Registry (ghcr.io)**.

**Naming Convention:**
```
ghcr.io/<owner>/<image-name>:<tag>
```

**Example:**
```
ghcr.io/smana/pev2:latest
ghcr.io/smana/pev2:v1.17.0
ghcr.io/smana/pev2:main-abc1234
```

## Security

### Vulnerability Scanning

All images are automatically scanned with **Trivy** for:
- 🔴 **CRITICAL** severity vulnerabilities
- 🟠 **HIGH** severity vulnerabilities

Results are:
- Uploaded to GitHub Security tab
- Stored as workflow artifacts (30 days)
- Block: No (informational only)

### Access Control

- **Read**: Public (ghcr.io allows anonymous pulls)
- **Write**: GitHub Actions via `GITHUB_TOKEN`
- **Push**: Requires repository write access

## Troubleshooting

### Build Failed

```bash
# Check workflow logs
gh run list --workflow=build-container-images.yml
gh run view <run-id> --log

# Common issues:
# - Dockerfile syntax error
# - Missing files in build context
# - Network timeout during downloads
```

### Image Not Building

```bash
# Verify change detection
git log --oneline --name-only | grep container-images

# Manually trigger build
gh workflow run build-container-images.yml -f image=<name>
```

### Security Scan Failed

```bash
# Download scan results
gh run download <run-id>

# Review SARIF file
cat security-scan-<image>/trivy-results-<image>.sarif | jq
```

## Best Practices

### Dockerfile Guidelines

1. **Base Images**
   - ✅ Use specific tags: `alpine:3.19` (not `alpine:latest`)
   - ✅ Prefer official images: `nginx:alpine`, `node:20-alpine`
   - ✅ Use minimal variants: Alpine, Distroless, Scratch

2. **Security**
   - ✅ Run as non-root user
   - ✅ Use read-only filesystem when possible
   - ✅ Drop all capabilities
   - ✅ Scan regularly with Trivy

3. **Optimization**
   - ✅ Multi-stage builds to minimize size
   - ✅ Order layers by change frequency (least → most)
   - ✅ Combine RUN commands to reduce layers
   - ✅ Use .dockerignore to exclude unnecessary files

4. **Documentation**
   - ✅ Add comments explaining non-obvious steps
   - ✅ Document exposed ports
   - ✅ Include HEALTHCHECK
   - ✅ Create README.md with usage instructions

### Build Script Template

```bash
#!/bin/bash
set -e

VERSION="v1.0.0"
REGISTRY="${CONTAINER_REGISTRY:-ghcr.io/smana}"
IMAGE_NAME="<image-name>"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"

docker build \
  --platform linux/amd64 \
  -t "${FULL_IMAGE}" \
  -t "${REGISTRY}/${IMAGE_NAME}:latest" \
  .

echo "✅ Build successful: ${FULL_IMAGE}"
echo "To push: docker push ${FULL_IMAGE}"
```

## Related Documentation

- **GitHub Actions**: `.github/workflows/build-container-images.yml`
- **Individual Images**: See `container-images/<image-name>/README.md`
- **Deployment**: See `tooling/` or `apps/` directories

## Support

For issues with:
- **Workflow**: Check `.github/workflows/build-container-images.yml`
- **Specific Image**: Check `container-images/<image-name>/README.md`
- **Registry Access**: Contact repository administrators
