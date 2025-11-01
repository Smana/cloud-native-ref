#!/usr/bin/env bash

# =============================================================================
# Benchmark Images Cleanup Script
# =============================================================================
#
# Removes benchmark-generated images from both database and S3 storage.
# Identifies images by filename patterns: 'bench-image-*' or 'mixed-*'
#
# Usage:
#   ./cleanup-benchmark-images.sh [OPTIONS]
#
# Options:
#   --namespace NS    Kubernetes namespace (default: apps)
#   --app NAME        App name (default: xplane-image-gallery)
#   --dry-run         Show what would be deleted without deleting
#   -h, --help        Show this help message
#

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-apps}"
APP_NAME="${APP_NAME:-xplane-image-gallery}"
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --app)
            APP_NAME="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            grep "^#" "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  🧹 Benchmark Images Cleanup${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# Get database pod
DB_POD=$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=${APP_NAME}-cnpg-cluster,cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}')

if [[ -z "$DB_POD" ]]; then
    echo -e "${RED}[✗] Could not find database pod${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] Found database pod: $DB_POD${NC}"

# Count benchmark images
echo -e "\n${BLUE}[INFO] Checking for benchmark images...${NC}"
STATS=$(kubectl exec -n "$NAMESPACE" "$DB_POD" -- psql -U postgres -d image-gallery -t -c "
    SELECT
        COUNT(*) as count,
        pg_size_pretty(SUM(file_size)::bigint) as total_size
    FROM images
    WHERE original_filename LIKE '%bench%' OR original_filename LIKE '%mixed%';
" 2>/dev/null | grep -v "^Defaulted" | xargs)

COUNT=$(echo "$STATS" | awk '{print $1}')
SIZE=$(echo "$STATS" | awk '{print $3}')

if [[ "$COUNT" == "0" ]]; then
    echo -e "${GREEN}[✓] No benchmark images found${NC}"
    exit 0
fi

echo -e "${YELLOW}[⚠] Found $COUNT benchmark images (${SIZE})${NC}"
echo

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${BLUE}[INFO] Dry run mode - showing images that would be deleted:${NC}"
    kubectl exec -n "$NAMESPACE" "$DB_POD" -- psql -U postgres -d image-gallery -c "
        SELECT id, filename, original_filename, pg_size_pretty(file_size::bigint) as size
        FROM images
        WHERE original_filename LIKE '%bench%' OR original_filename LIKE '%mixed%'
        ORDER BY id;
    " 2>/dev/null | grep -v "^Defaulted"
    echo
    echo -e "${YELLOW}[INFO] Run without --dry-run to actually delete these images${NC}"
    exit 0
fi

# Confirm deletion
echo -e "${YELLOW}[⚠] This will delete $COUNT images from database and S3${NC}"
read -p "Are you sure? (yes/no): " -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo -e "${BLUE}[INFO] Cancelled${NC}"
    exit 0
fi

echo
echo -e "${BLUE}[INFO] Deleting benchmark images...${NC}"

# Delete from database (cascade will handle related records)
# The application's storage cleanup should handle S3 deletion if implemented
# Otherwise, images will remain in S3 but won't be accessible from API
kubectl exec -n "$NAMESPACE" "$DB_POD" -- psql -U postgres -d image-gallery -c "
    DELETE FROM images
    WHERE original_filename LIKE '%bench%' OR original_filename LIKE '%mixed%';
" 2>/dev/null | grep -v "^Defaulted"

echo
echo -e "${GREEN}[✓] Deleted $COUNT benchmark images from database${NC}"

# Clean up S3 files
echo
echo -e "${BLUE}[INFO] Cleaning up S3 bucket...${NC}"

# Get bucket name from App CR
BUCKET_NAME=$(kubectl get app -n "$NAMESPACE" "$APP_NAME" -o jsonpath='{.spec.s3Bucket.name}' 2>/dev/null || echo "")

if [[ -z "$BUCKET_NAME" ]]; then
    # Fallback: construct bucket name from region and app name
    REGION=$(kubectl get app -n "$NAMESPACE" "$APP_NAME" -o jsonpath='{.spec.s3Bucket.region}' 2>/dev/null || echo "eu-west-3")
    BUCKET_NAME="${REGION}-ogenki-${APP_NAME}"
fi

echo -e "${BLUE}[INFO] S3 Bucket: $BUCKET_NAME${NC}"

S3_DELETE_OUTPUT=$(aws s3 rm "s3://${BUCKET_NAME}/" --recursive --exclude "*" --include "*bench-image*" --include "*mixed-*" 2>&1)
S3_DELETE_COUNT=$(echo "$S3_DELETE_OUTPUT" | grep -c "^delete:" || echo "0")

if [[ "$S3_DELETE_COUNT" -gt 0 ]]; then
    echo -e "${GREEN}[✓] Deleted $S3_DELETE_COUNT files from S3${NC}"
else
    echo -e "${BLUE}[INFO] No benchmark files found in S3${NC}"
fi

echo
echo -e "${GREEN}[✓] Cleanup complete!${NC}"
