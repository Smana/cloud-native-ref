#!/usr/bin/env bash
#
# Make the workforce pool survivable across a teardown/rebuild cycle.
#
# THE PROBLEM
#
# Workforce pools SOFT-DELETE with a 30-day purge. `tofu destroy` removes the
# pool and empties the state, but the NAME stays reserved for those 30 days --
# so the next `tofu apply` fails on its very first resource:
#
#   Error 409: Pool locations/global/workforcePools/<name> already exists.
#
# For a platform whose clusters are deliberately throwaway, a rebuild inside 30
# days is the normal case, not an edge case. Measured 2026-09-02: a bootstrap
# died nine seconds in, on the first stack, for exactly this.
#
# WHAT MAKES IT WORSE THAN A PLAIN 409
#
# `gcloud iam workforce-pools list` HIDES deleted pools. Every check says the
# org is clean, the sweep says the org is clean, and the apply still fails
# claiming the pool exists. You have to know to pass --show-deleted before any
# evidence of the cause appears.
#
# WHAT THIS DOES
#
# Idempotent reconciliation, run before the apply:
#
#   pool DELETED                  -> undelete it
#   provider DELETED              -> undelete it (a pool's undelete does NOT
#                                    restore its providers; they are separate
#                                    objects with their own lifecycle)
#   exists but absent from state  -> import it, so the apply updates rather
#                                    than re-creates
#   active and already in state   -> do nothing
#
# After this, `tofu plan` on an untouched pool reports no changes -- verified.
#
# WHY NOT JUST USE A UNIQUE NAME PER BUILD
#
# Because the pool id is embedded verbatim in every Kubernetes RBAC group
# string. A per-build name means every binding changes every build, and the
# 30-day tombstones accumulate. A stable name that survives rebuilds is the
# property worth having; this script is what buys it.
#
# Usage (from the workforce-identity stack directory):
#   gcp-adopt-workforce-pool.sh --pool NAME [--provider NAME] [--location L] [--apply]
#
# Dry-run unless --apply.

set -o nounset
set -o pipefail

POOL=""
PROVIDER="zitadel"
LOCATION="global"
APPLY="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --pool)     POOL="$2"; shift 2 ;;
        --provider) PROVIDER="$2"; shift 2 ;;
        --location) LOCATION="$2"; shift 2 ;;
        --apply)    APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$POOL" ] || { echo "--pool is required" >&2; exit 2; }

if ! command -v gcloud >/dev/null 2>&1; then
    echo "[adopt] gcloud not available; skipping." >&2
    exit 0
fi

pool_path="locations/${LOCATION}/workforcePools/${POOL}"
provider_path="${pool_path}/providers/${PROVIDER}"

# `describe` sees deleted objects; `list` does not. That asymmetry is the whole
# reason this is hard to diagnose by hand.
pool_state="$(gcloud iam workforce-pools describe "$POOL" --location="$LOCATION" \
                --format='value(state)' 2>/dev/null || true)"

if [ -z "$pool_state" ]; then
    echo "[adopt] pool ${POOL} does not exist; the apply will create it."
    exit 0
fi

echo "[adopt] pool ${POOL} is ${pool_state}"

if [ "$pool_state" = "DELETED" ]; then
    if [ "$APPLY" != "true" ]; then
        echo "[adopt] (dry-run) would undelete the pool"
    else
        echo "[adopt] undeleting the pool -- its name is reserved for 30 days and"
        echo "[adopt] the apply would otherwise fail 409 claiming it already exists"
        gcloud iam workforce-pools undelete "$POOL" --location="$LOCATION" >/dev/null 2>&1 \
            || { echo "[adopt] FAILED to undelete ${POOL}" >&2; exit 1; }
    fi
fi

# Separate object, separate lifecycle: undeleting a pool leaves its providers
# deleted, which presents later as a working pool that trusts nothing.
provider_state="$(gcloud iam workforce-pools providers describe "$PROVIDER" \
                    --workforce-pool="$POOL" --location="$LOCATION" \
                    --format='value(state)' 2>/dev/null || true)"
if [ "$provider_state" = "DELETED" ]; then
    if [ "$APPLY" != "true" ]; then
        echo "[adopt] (dry-run) would undelete provider ${PROVIDER}"
    else
        echo "[adopt] undeleting provider ${PROVIDER}"
        gcloud iam workforce-pools providers undelete "$PROVIDER" \
            --workforce-pool="$POOL" --location="$LOCATION" >/dev/null 2>&1 \
            || echo "[adopt] could not undelete provider ${PROVIDER}; the apply will try to create it" >&2
    fi
fi

# Import anything that exists but is not tracked, so the apply updates instead
# of colliding. Requires an initialised working directory; tolerated if not.
if ! command -v tofu >/dev/null 2>&1; then
    echo "[adopt] tofu not available; skipping state adoption." >&2
    exit 0
fi
if [ ! -d .terraform ]; then
    echo "[adopt] not an initialised stack directory; skipping state adoption." >&2
    exit 0
fi

state="$(tofu state list 2>/dev/null || true)"

adopt() {  # $1 = resource address, $2 = import id
    local addr="$1" id="$2"
    if grep -qx "$addr" <<<"$state"; then
        echo "[adopt] ${addr} already in state"
        return 0
    fi
    if [ "$APPLY" != "true" ]; then
        echo "[adopt] (dry-run) would import ${addr}"
        return 0
    fi
    echo "[adopt] importing ${addr}"
    tofu import -var-file=variables.tfvars "$addr" "$id" >/dev/null 2>&1 \
        || echo "[adopt] import of ${addr} failed; the apply may collide" >&2
}

adopt google_iam_workforce_pool.zitadel "$pool_path"
if [ -n "$provider_state" ]; then
    adopt google_iam_workforce_pool_provider.zitadel "$provider_path"
fi

echo "[adopt] done"
