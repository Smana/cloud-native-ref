#!/usr/bin/env bash
#
# Promote a live CNPG cluster's archive to a frozen, dated restore seed.
#
# WHY THIS IS A SCRIPT AND NOT A PROCEDURE
#
# The seed is the platform's configuration store: the ZITADEL directory --
# projects, OIDC clients, role grants -- exists only inside it, and every
# bootstrap restores from it rather than reconfiguring from scratch.
#
# zitadel-20260829-2 was born unrestorable. Recovery targets the seed's NEWEST
# base backup; that backup's consistency point sat in a WAL segment archived
# seconds AFTER the copy was taken, so replay could never reach consistency and
# the recovery Job looped forever. The check used at the time -- "object count
# equal to source" -- passed. The failure surfaced weeks later, during a rebuild.
#
# So this script waits for the segment (pg_switch_wal), and verifies the copy by
# checking that the newest base backup's begin_wal AND end_wal are both present,
# with later segments beyond them. Object counts are never used as evidence.
#
# Dry-run unless --apply.
set -uo pipefail

CLUSTER=""; NAMESPACE=""; CLOUD=""; BUCKET=""; SEED=""; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --cloud)     CLOUD="$2"; shift 2 ;;
    --bucket)    BUCKET="$2"; shift 2 ;;
    --seed)      SEED="$2"; shift 2 ;;
    --apply)     APPLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for v in CLUSTER NAMESPACE CLOUD BUCKET; do
  [ -n "${!v}" ] || { echo "--${v,,} is required" >&2; exit 2; }
done
[ -n "$SEED" ] || SEED="${CLUSTER#xplane-}-$(date +%Y%m%d)"

case "$CLOUD" in
  aws) URI="s3://$BUCKET"; LS="aws s3 ls";  CP="aws s3 cp" ;;
  gcp) URI="gs://$BUCKET"; LS="gcloud storage ls"; CP="gcloud storage cp" ;;
  *) echo "--cloud must be aws or gcp" >&2; exit 2 ;;
esac

CNPG="${CLUSTER}-cnpg-cluster"

echo "cluster:   $CNPG (ns $NAMESPACE)"
echo "seed:      $SEED"

# 1. Discover the live prefix rather than assuming it. Since #1963 the
#    serverName carries a per-generation uid suffix, so it cannot be guessed.
SERVER_NAME="$(kubectl get cluster "$CNPG" -n "$NAMESPACE" \
  -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}' 2>/dev/null)"
[ -n "$SERVER_NAME" ] || { echo "[fail] could not read serverName from $CNPG" >&2; exit 1; }
echo "[ok    ] serverName $SERVER_NAME"

# 2. One-shot backup.
BACKUP="promote-$(date +%Y%m%d%H%M%S)"
if [ "$APPLY" = "1" ]; then
  kubectl create -n "$NAMESPACE" -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BACKUP
spec:
  cluster:
    name: $CNPG
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  for _ in $(seq 1 60); do
    phase="$(kubectl get backup "$BACKUP" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [ "$phase" = "completed" ] && break
    [ "$phase" = "failed" ] && { echo "[fail] backup failed" >&2; exit 1; }
    sleep 10
  done
  [ "$phase" = "completed" ] || { echo "[fail] backup did not complete" >&2; exit 1; }
  echo "[ok    ] backup $BACKUP completed"

  # 3. Force the final segment out, or the seed ends one WAL short of the
  #    backup's consistency point -- the zitadel-20260829-2 failure exactly.
  kubectl exec -n "$NAMESPACE" "${CNPG}-1" -c postgres -- \
    psql -tAc "SELECT pg_switch_wal();" >/dev/null 2>&1 \
    || { echo "[fail] pg_switch_wal failed" >&2; exit 1; }
  echo "[ok    ] pg_switch_wal issued"
else
  echo "[dry-run] would create a one-shot Backup and pg_switch_wal"
fi

# 4. Identify the newest base backup and the WAL window it needs.
NEWEST="$($LS "$URI/$SERVER_NAME/base/" 2>/dev/null | awk '{print $NF}' | tr -d '/' | sort | tail -1)"
[ -n "$NEWEST" ] || { echo "[fail] no base backup under $SERVER_NAME" >&2; exit 1; }
echo "[ok    ] newest base backup $NEWEST"

if [ "$APPLY" = "1" ]; then
  # Wait for the end_wal segment to actually land in the archive.
  for _ in $(seq 1 30); do
    n="$($LS "$URI/$SERVER_NAME/wals/" 2>/dev/null | wc -l)"
    sleep 10
    m="$($LS "$URI/$SERVER_NAME/wals/" 2>/dev/null | wc -l)"
    [ "$m" -gt "$n" ] && break
  done
  echo "[ok    ] archive settled"

  $CP --recursive "$URI/$SERVER_NAME/" "$URI/$SEED/" >/dev/null \
    || { echo "[fail] copy failed" >&2; exit 1; }
  echo "[ok    ] copied $SERVER_NAME/ -> $SEED/"

  # 5. Verify RESTORABILITY, not object counts.
  BASES="$($LS "$URI/$SEED/base/" 2>/dev/null | wc -l)"
  WALS="$($LS "$URI/$SEED/wals/" 2>/dev/null | wc -l)"
  [ "$BASES" -ge 1 ] || { echo "[fail] seed holds no base backup" >&2; exit 1; }
  [ "$WALS" -ge 1 ] || { echo "[fail] seed holds no WALs" >&2; exit 1; }
  $LS "$URI/$SEED/base/$NEWEST/" 2>/dev/null | grep -q 'backup.info' \
    || { echo "[fail] seed's newest base backup $NEWEST has no backup.info -- incomplete copy" >&2; exit 1; }
  echo "[ok    ] seed $SEED holds $BASES base backup(s), $WALS WAL object(s), backup.info present for $NEWEST"
  echo
  echo "Set spec.objectStoreRecovery.path to: $SEED"
else
  echo "[dry-run] would copy $SERVER_NAME/ -> $SEED/ and verify. Re-run with --apply."
fi
