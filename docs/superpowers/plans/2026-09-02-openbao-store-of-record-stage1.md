# OpenBao Store of Record — Stage 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the OpenBao *lineage* (persistent seal key, snapshot buckets, bootstrap secrets), rehydrate OpenBao from its latest Raft snapshot on every boot, replace AppRole with cluster-issued JWTs, move the AWS PKI under the offline root, mirror snapshots to GCS, and prove an AWS → GCP fallback — **without repointing the `ClusterSecretStore`** (that is Stage 2).

**Architecture:** Two new persistent OpenTofu stacks (`opentofu/aws/openbao/lineage`, `opentofu/gcp/openbao/lineage`) hold what a rebuilt OpenBao needs to come back. Both OpenBao cluster stacks move to Raft and read their seal from the lineage. The management stacks' deploy workflow gains a `rehydrate` step that restores the newest snapshot into a freshly initialised node. Each cluster's `configure` stack owns that cluster's JWT auth mount (it is the only stack that knows the EKS issuer, which changes per rebuild). The federation stack gains an `accounts.google.com` OIDC provider and two roles so a GCP node can use the AWS KMS seal and Google's Storage Transfer Service can pull the S3 bucket.

**Tech Stack:** OpenTofu ≥ 1.8 with `hashicorp/aws ~> 6`, `hashicorp/google ~> 7.17`, `hashicorp/vault ~> 5`, `hashicorp/tls ~> 4`; Terramate scripts; OpenBao 2.6.2 (`awskms` / `gcpckms` seals, Raft, JWT auth); External Secrets Operator; cert-manager 1.21; Tailscale operator 1.90.6 (`ProxyGroup` egress); GitHub Actions OIDC; bash/sh scripts under `scripts/`.

**Design:** [`docs/superpowers/specs/2026-09-02-openbao-store-of-record-design.md`](../specs/2026-09-02-openbao-store-of-record-design.md). Read its "Target architecture" and "Risks" sections before starting. Where this plan deviates from the design it says so inline, with the reason.

---

## Conventions for every task

- **Worktree.** Work in the `openbao-lineage` worktree this plan was written in (`.claude/worktrees/openbao-lineage`, branch `worktree-openbao-lineage`). Never commit on `main`.
- **Commits.** One commit per task, message in `type(scope): summary` form. **Never add a `Co-Authored-By` trailer** (user rule).
- **Commit with an explicit pathspec: `git commit -F <msgfile> -- <paths>`.** A bare
  `git commit` commits the whole **index**, not the paths you just added — so if
  anything else is staged (another agent in the same worktree, a `git rm` from a
  parallel task, a pre-commit hook's fixup), it silently rides along in your
  commit. This has already happened once here: three of Task 7's deletions landed
  in an unrelated plan-fix commit. Also write the message to a **file** rather
  than passing `-m "..."`: a backtick in a double-quoted message is command
  substitution, and the shell will execute it.
- **A new `variables.tfvars` must be force-added.** `.gitignore:55` is a blanket
  `*.tfvars`, so `git add` silently skips it and the file stays untracked — it then
  does not exist on a fresh clone, while `deploy` and `destroy` both pass
  `-var-file=variables.tfvars`. Every existing stack force-adds its own; do the same:
  `git add -f <stack>/variables.tfvars`, then confirm with `git ls-files <path>`
  (empty output means it is still untracked). Applies to Tasks 3 and 8.
- **Pre-commit runs on every commit**: trailing whitespace, terraform fmt/validate/tflint, detect-secrets. A field name such as `kubernetesServiceAccountToken` trips detect-secrets; append ` # pragma: allowlist secret` on that line.
- **Validators** (from the repo root, expected exit 0 unless stated):
  - `./scripts/validate-manifests.sh` — after any change under `security/`, `observability/`, `clusters/`, `scripts/flux-schema/`. Report must end `Invalid: 0, Skipped: 0`.
  - `python3 scripts/flux-schema/check-substitution.py` — after any change to a `flux_cluster_vars` ConfigMap or a `${var}` in a manifest.
  - `./scripts/validate-links.sh` and `./scripts/validate-doc-claims.sh` — after any doc change.
  - `tofu fmt -recursive opentofu/ && (cd opentofu/<stack> && tofu init -backend=false && tofu validate)` — after any HCL change. `-backend=false` avoids needing cloud credentials for validation.
  - `shellcheck -x -S warning scripts/openbao-config.sh` — after script changes. **Use CI's exact flags** (`.github/workflows/ci.yaml:212` runs `find ./scripts -name "*.sh" | xargs -0 shellcheck -x -S warning`). Plain `shellcheck` exits 1 on a pre-existing info-level `SC1091` for the `lib/gcloud-adc.sh` source line; `-x` follows the source and `-S warning` filters info, which is the gate that actually has to pass. For the POSIX sibling, `shellcheck -s sh container-images/openbao-snapshot/openbao-snapshot.sh` (it lives outside `./scripts`, so CI's find does not reach it through the symlink).
- **Cloud credentials.** Tasks marked **[LIVE]** talk to AWS/GCP or a running OpenBao and need: an AWS session for the `ogenki` account, `gcloud auth application-default login` for project `ogenki-435905`, and a tailnet connection. Everything else is offline.
- **Fixed values used throughout** (do not invent alternatives):

  | Thing | Value |
  |---|---|
  | AWS seal key alias | `alias/openbao-seal` (primary `eu-west-3`, replica `eu-west-1`) |
  | AWS snapshot bucket / its key alias | `eu-west-3-ogenki-openbao-snapshot` / `alias/xplane-openbao-snapshot` |
  | GCS snapshot bucket | `ogenki-435905-ogenki-openbao-snapshot` |
  | AWS roles | `openbao-standby-seal`, `openbao-snapshot-mirror`, `openbao-restore-drill` |
  | GCP service accounts | `openbao-node` (lineage; the standby VM), `openbao-drill` (lineage; CI) |
  | JWT auth mounts / roles / audience | `jwt/aws-0`, `jwt/gcp-0` / `cert-manager`, `external-secrets`, `openbao-snapshot` / `openbao` |
  | Neutral in-cluster name | `openbao.security.svc.cluster.local:8200` |
  | Freshness marker | root-namespace kv-v2 mount `lineage/`, key `check_timestamp` |
  | New AWS Secrets Manager entries | `certificates/priv.aws.ogenki.io/intermediate-ca` (`{"bundle": "<cert>\n<key>"}`), `certificates/priv.aws.ogenki.io/ca-chain` (`{"ca": "<intermediate>\n<root>"}`) |
  | Removed AWS Secrets Manager entries | `certificates/priv.aws.ogenki.io/root-ca`, `openbao/cloud-native-ref/approles/cert-manager`, `security/openbao/openbao-snapshot` |
  | Removed GCP Secret Manager entries | `openbao-priv-gcp-approle-cert-manager`, `openbao-priv-gcp-snapshot` |
  | Destroy gates | `TM_LINEAGE_DESTROY=true` (lineage + management stacks), `TM_OPENBAO_SKIP_SNAPSHOT=true` (skip the pre-destroy snapshot) |
  | New Flux variables | `openbao_snapshot_bucket` (both clusters), `openbao_target_ip` (gcp-0 only) |
  | Removed Flux variables | `openbao_snapshot_secret`, `cert_manager_approle_id` |
  | Snapshot image | `ghcr.io/smana/openbao-snapshot:v0.2.0` |

## Deviations from the design, stated once

1. **Local/remote form of the `openbao` Service is a committed overlay choice, not a Flux variable.** Flux `postBuild` substitutes strings and cannot select a manifest. The *address* (`openbao_target_ip`) is the variable; the *form* is which `openbao-endpoint/{local,remote}` directory a cluster's overlay lists (Task 7).
2. **The CI drill does not assert `check_timestamp`.** Reading it needs a token, which CI could only obtain from the recovery keys. The drill asserts what unauthenticated endpoints prove (unsealed with the lineage seal; PKI issuer chains to the committed root; the mirror holds the newest object that has had `MIRROR_GRACE_HOURS` to cross). The grace window is deliberate and is a second deviation in itself: a Storage Transfer schedule is an *earliest start time*, so asserting the very newest object turns ordinary backend queuing into a red build, and a weekly job that cries wolf gets switched off — which costs more than the bug it exists to catch. Rehydrate, run by an operator, still checks the marker (Task 12).
3. **Failback mirroring (GCS → S3) is a manual step in the runbook**, not a `gcp-0` CronJob permission. A standby's snapshot must not silently become the "newest" object mirrored over the AWS lineage's history; the operator copies exactly one object deliberately (Task 13 guide, Task 18 Step 4).
4. **The GCP seal key stays a hand-created prerequisite.** The design's lineage table listed it; it was already outside every stack (`opentofu/gcp/openbao/cluster/kms.tf`), which is the property wanted. Nothing to move (Task 8).

## File map

| Path | Task | Responsibility |
|---|---|---|
| `container-images/openbao-snapshot/openbao-snapshot.sh` (the real file; `scripts/openbao-snapshot.sh` is a **symlink** to it) | 1 | save/restore; auth by `VAULT_TOKEN`, JWT, or AppRole; stamps `lineage/check_timestamp` on save; `--freshness warn\|fail` |
| `container-images/openbao-snapshot/Dockerfile` | 1 | image version `0.2.0` |
| `scripts/openbao-config.sh` | 2 | `rehydrate` and `pre-destroy-snapshot` subcommands, `--ca-file`, `--snapshot-bucket` |
| `opentofu/aws/openbao/lineage/*` | 3 | multi-region seal key, imported snapshot bucket + key, GitHub OIDC drill role, destroy gate |
| `security/aws-0/openbao-snapshot/{kms,s3-bucket}.yaml` | 3 | deleted (moved to lineage) |
| `opentofu/aws/openbao/cluster/*` | 4 | seal from lineage alias, Raft in `dev`, fixed NLB IPs, pre-destroy snapshot |
| `opentofu/config.tm.hcl` | 5 | globals: `snapshot_bucket_name`, `ca_chain_secret_name`, `intermediate_ca_secret_name` |
| `opentofu/aws/openbao/management/*` | 5 | rehydrate step, destroy gate, `lineage/` mount, PKI from pre-signed intermediate, AppRole removed |
| `opentofu/aws/eks/configure/*` | 6 | vault provider, `jwt/aws-0` mount + roles, ConfigMap vars, approle Secret removed |
| `security/base/openbao-endpoint/{local,remote}/*` | 7 | the neutral `openbao` Service, two forms |
| `security/{aws-0,gcp-0}/openbao/*`, `security/base/openbao-snapshot/*`, `observability/base/.../externalsecret-openbao-ca.yaml`, `clusters/aws-0/security/security-openbao.yaml`, `scripts/flux-schema/render-bundle.py` | 7 | consumers switched to JWT + neutral name; secrets removed |
| `opentofu/shared/tailscale/main.tf` | 7 | `tag:k8s` → advertised CIDRs on 8200 |
| `opentofu/gcp/openbao/lineage/*` | 8 | imported GCS bucket, `openbao-node` + `openbao-drill` SAs, Storage Transfer job, GitHub WIF pool |
| `opentofu/shared/aws-gcp-federation/google-identity.tf`, `variables.tf` | 9 | `accounts.google.com` provider, `openbao-standby-seal`, `openbao-snapshot-mirror` |
| `opentofu/gcp/openbao/cluster/*` | 10 | SA from lineage, Raft, `seal_provider`, AWS token timer, pre-destroy snapshot |
| `opentofu/gcp/openbao/management/*`, `opentofu/gcp/gke/configure/*` | 11 | rehydrate, destroy gate, `lineage/` mount, AppRole removed, `jwt/gcp-0` |
| `.github/workflows/openbao-restore-drill.yml` | 12 | weekly restore drill |
| `website/content/docs/decisions/0032-*.md`, amendments, pages, `CLAUDE.md`, `.doc-claims.yaml` | 13 | records |
| Live tasks | 14–18 | PKI ceremony, imports, deploys, drills |

Tasks 1–13 are offline and can each be validated without a cluster. Tasks 14–18 are **[LIVE]** and must run in order.

---

### Task 1: `openbao-snapshot.sh` — three auth modes, freshness switch, save-time stamp

**Files:**
- Modify: `scripts/openbao-snapshot.sh`
- Modify: `container-images/openbao-snapshot/openbao-snapshot.sh` — **this is the real file.** `scripts/openbao-snapshot.sh` is a committed symlink to it (git mode `120000`), so the two are the same inode and byte-identity is structural, not maintained by copying. Edit the `container-images/` path; every `scripts/openbao-snapshot.sh` reference elsewhere resolves through the symlink.
- Modify: `container-images/openbao-snapshot/Dockerfile:12` (add a version ARG the build workflow tags from)

The script is `#!/bin/sh` (POSIX, no arrays, no `pipefail`). Keep it that way.

- [ ] **Step 1: Replace the unconditional `HOME` export**

Find:

```sh
# Writable volume
export HOME=/snapshot
```

Replace with:

```sh
# Writable scratch dir. The CronJob mounts an emptyDir at /snapshot; an operator
# shell has no such directory, and the previous unconditional export made every
# write under $HOME (the generate-root nonce file, gcloud's config) abort a
# restore under `set -e`. Use it when it is there, otherwise leave HOME alone.
if [ -d /snapshot ] && [ -w /snapshot ]; then
    export HOME=/snapshot
fi
```

- [ ] **Step 2: Move the freshness marker to a root-namespace mount**

Find:

```sh
# Where the restore freshness marker lives. The kv-v2 mount is in the `app`
# tenant namespace — platform services live in root, tenants get namespaces.
CHECK_NAMESPACE="${CHECK_NAMESPACE:-app}"
CHECK_PATH="${CHECK_PATH:-secret/check_timestamp}"
```

Replace with:

```sh
# Where the freshness marker lives: the root-namespace `lineage/` kv-v2 mount
# both management stacks create. It used to be `app/secret/check_timestamp`, but
# GCP has no `app` namespace, so the restore path 404'd there, and a tenant
# namespace is the wrong home for a platform marker anyway. CHECK_NAMESPACE is
# kept for operators with an older snapshot; empty means root.
CHECK_NAMESPACE="${CHECK_NAMESPACE:-}"
CHECK_PATH="${CHECK_PATH:-lineage/check_timestamp}"

# `bao kv ... -namespace=""` is not the same as omitting the flag, so build it.
kv_ns_flag() {
    if [ -n "${CHECK_NAMESPACE}" ]; then
        printf -- '-namespace=%s' "${CHECK_NAMESPACE}"
    fi
}
```

- [ ] **Step 3: Add the `--freshness` option to the parser**

Find the `usage()` line:

```sh
      -d | --days               : Number of days for snapshot validation (default: ${DEFAULT_DAYS} days)
```

Add directly after it:

```sh
      -f | --freshness          : What to do when the restored marker is older than --days,
                                  OR absent altogether: "fail" (default) exits non-zero,
                                  "warn" logs and continues. This is an ALARM, not a gate --
                                  the marker can only be read after the restore has already
                                  been applied, so it tells you (and any calling automation,
                                  via the exit code) that what you installed is stale. Use
                                  "warn" when restoring into an EMPTY node (a rehydrate),
                                  where a stale restore is still better than none, and where
                                  a lineage's first snapshot may legitimately carry no marker.
```

Also fix the synopsis line, which still omits the flag. Find:

```sh
Usage: ./${SCRIPT_NAME} [save|restore] -s <snapshot_file> -b <bucket_name> -a <VAULT_ADDR> [-d <days>]
```

Replace with:

```sh
Usage: ./${SCRIPT_NAME} [save|restore] -s <snapshot_file> -b <bucket_name> -a <VAULT_ADDR> [-d <days>] [-f fail|warn]
```

And document the environment, which is the real contract for this script's three
callers (a CronJob, an operator, and the `rehydrate` step) and today is learnable
only by hitting an error path. Add directly above the `      ex:` line:

```sh
      Environment:
      VAULT_TOKEN               : an existing token. Takes precedence over everything below.
      OPENBAO_JWT_MOUNT         : e.g. jwt/aws-0    ) all three together select JWT login,
      OPENBAO_JWT_ROLE          : e.g. openbao-snapshot ) which is how the CronJob
      OPENBAO_JWT_PATH          : path to a projected SA token ) authenticates.
      APPROLE_ROLE_ID           : ) legacy AppRole login, still accepted
      APPROLE_SECRET_ID         : )
      RECOVERY_KEYS_SECRET_ID   : required by 'restore' -- names the secret-store entry
                                  holding the recovery keys a root token is minted from.
      CLOUD                     : aws (default) | gcp -- selects which CLI moves the object.
      VAULT_CACERT              : CA chain to verify the server. Set it; do not skip verify.
      CHECK_NAMESPACE           : override the marker's namespace (default: root).
      CHECK_PATH                : override the marker path (default: lineage/check_timestamp).
```

Find:

```sh
COMMAND=$1
NUM_DAYS=${DEFAULT_DAYS}
shift
```

Replace with:

```sh
COMMAND=$1
NUM_DAYS=${DEFAULT_DAYS}
FRESHNESS=fail
shift
```

Find:

```sh
    -d | --days) NUM_DAYS=$2; shift 2;;
```

Add directly after it:

```sh
    -f | --freshness) FRESHNESS=$2; shift 2;;
```

Find:

```sh
if ! echo "${NUM_DAYS}" | grep -E '^[0-9]+$' > /dev/null; then
    echo "${err}: Number of days must be a positive integer (--days)!"
    usage
    exit 1
fi
```

Add directly after it:

```sh
case "${FRESHNESS}" in
    fail|warn) ;;
    *) echo "${err}: --freshness must be 'fail' or 'warn', got '${FRESHNESS}'."; usage; exit 1;;
esac
```

- [ ] **Step 4: Remove the AppRole precondition and rewrite `authenticate()`**

Delete this block entirely:

```sh
# Check required environment variables
if [ -z "${APPROLE_ROLE_ID}" ] || [ -z "${APPROLE_SECRET_ID}" ]; then
    echo "${err}: The environment variables APPROLE_ROLE_ID and APPROLE_SECRET_ID must be set"
    exit 1
fi
```

Find the whole `authenticate()` function (from its comment `# One AppRole login per run.` through the closing `}`) and replace it with:

```sh
# Three ways in, tried in order. VAULT_TOKEN wins so an operator (or the
# rehydrate step, which holds a fresh root token) can drive save/restore
# directly; the JWT path is what the CronJob uses; AppRole is kept for a
# snapshot taken by hand against a lineage that predates the JWT mounts.
authenticate() {
    if [ -n "${VAULT_TOKEN:-}" ]; then
        echo "${info}: Using the token supplied in VAULT_TOKEN."
        export VAULT_TOKEN
        return 0
    fi

    if [ -n "${OPENBAO_JWT_PATH:-}" ]; then
        if [ -z "${OPENBAO_JWT_MOUNT:-}" ] || [ -z "${OPENBAO_JWT_ROLE:-}" ]; then
            echo "${err}: OPENBAO_JWT_PATH is set; OPENBAO_JWT_MOUNT (e.g. jwt/aws-0) and OPENBAO_JWT_ROLE are required with it."
            exit 1
        fi
        echo "${info}: Authenticating with OpenBao via auth/${OPENBAO_JWT_MOUNT} as role ${OPENBAO_JWT_ROLE}..."
        # `jwt=@file` makes bao read the projected ServiceAccount token from disk,
        # so the token never appears on a command line.
        VAULT_TOKEN=$(bao write -field=token "auth/${OPENBAO_JWT_MOUNT}/login" \
            role="${OPENBAO_JWT_ROLE}" jwt=@"${OPENBAO_JWT_PATH}")
    elif [ -n "${APPROLE_ROLE_ID:-}" ] && [ -n "${APPROLE_SECRET_ID:-}" ]; then
        echo "${info}: Authenticating with OpenBao via AppRole..."
        # secret_id on STDIN, not argv: argv is readable through
        # /proc/<pid>/cmdline and `ps` by anything in the same PID namespace.
        # `printf` is a shell builtin, so this spawns no extra process. Same
        # reasoning as the root-token fix in openbao-config.sh's init.
        VAULT_TOKEN=$(printf '%s' "${APPROLE_SECRET_ID}" \
            | bao write -field=token auth/approle/login \
                role_id="${APPROLE_ROLE_ID}" secret_id=-)
    elif bao token lookup >/dev/null 2>&1; then
        # An operator who ran `bao login -method=userpass username=admin` -- the
        # flow CLAUDE.md documents -- has a token in ~/.vault-token and no
        # VAULT_TOKEN set. `bao` honours its own token helper, so a lookup
        # succeeding means every later call in this script will authenticate.
        # Without this branch a correctly-logged-in operator was told "no
        # credentials", which is a dead end during an incident.
        echo "${info}: Using the existing token from bao's token helper."
        return 0
    else
        echo "${err}: No OpenBao credentials. Set one of:"
        echo "${err}:   VAULT_TOKEN"
        echo "${err}:   OPENBAO_JWT_PATH + OPENBAO_JWT_MOUNT + OPENBAO_JWT_ROLE"
        echo "${err}:   APPROLE_ROLE_ID + APPROLE_SECRET_ID"
        echo "${err}: ...or run 'bao login' first. For a RESTORE on a node with no"
        echo "${err}: working auth method yet, none of these is needed: set"
        echo "${err}: RECOVERY_KEYS_SECRET_ID and a root token is minted from the"
        echo "${err}: recovery keys instead."
        # `return 1`, NOT `exit 1`: restore() treats a missing credential as
        # advisory (see below) and cannot do that if this function kills the
        # shell. save() turns it back into a hard failure at its call site.
        return 1
    fi

    if [ -z "${VAULT_TOKEN}" ]; then
        echo "${err}: Authentication failed. Unable to retrieve OpenBao token."
        return 1
    fi
    export VAULT_TOKEN
}
```

**`save()` keeps the hard failure**, explicitly. Find, inside `save()`:

```sh
    echo "${info}: Starting OpenBao backup to object storage..."
    check_required_bin
    authenticate
```

Replace with:

```sh
    echo "${info}: Starting OpenBao backup to object storage..."
    check_required_bin
    # A backup with no credential is not a backup. authenticate() returns
    # rather than exits, so the exit is chosen here -- restore() makes the
    # opposite choice deliberately.
    authenticate || exit 1
```

**Then make the call in `restore()` advisory.** This is the fix for a real dead
end: `restore()` calls `authenticate` and then never uses the resulting token —
`generate_root_token` (which needs no auth, only the recovery keys) overwrites
`VAULT_TOKEN` before the first `bao` call that matters. So a hard failure there
blocks the exact scenario restore exists for: a freshly initialised node with no
JWT mount and no AppRole, where none of the three credentials can be obtained but
the recovery keys are sitting in the secret store. It also leaked one unrevoked
token lease per restore. Find, inside `restore()`:

```sh
    echo "${info}: Restoring OpenBao from object storage..."
    check_required_bin
    authenticate
```

Replace with:

```sh
    echo "${info}: Restoring OpenBao from object storage..."
    check_required_bin
    # Advisory, not required. Nothing between here and the restore uses this
    # token: generate_root_token below mints one from the recovery keys, needs
    # no authentication, and overwrites VAULT_TOKEN. Demanding a credential
    # here would refuse the case this command exists for -- a node that is
    # initialised but has no usable auth method yet.
    if ! authenticate; then
        echo "${warn}: no ordinary credential available; continuing, because a"
        echo "${warn}: restore authenticates with the recovery keys instead."
    fi
```

- [ ] **Step 5: Stamp the marker in `save()`**

Find, inside `save()`:

```sh
    echo "${info}: Requesting a snapshot via ${VAULT_ADDR}"
    bao operator raft snapshot save "${SNAPSHOT_FILE}"
```

Replace with:

```sh
    # The marker records WHEN THE SNAPSHOT WAS TAKEN, so a later restore can
    # judge the age of what it just installed -- and, because it is read back
    # from inside the restored OpenBao, prove the restore actually applied.
    # It used to be written only on restore, which meant a lineage's first
    # snapshot carried no marker at all and the first rehydrate could not
    # judge anything.
    #
    # NON-FATAL, and that is the important part. Under `set -e` a failing
    # `bao kv put` here would abort save() BEFORE the snapshot below, so a
    # bookkeeping write would produce no backup at all. It will fail in
    # practice: the `lineage/` mount and the policy grant for it are created by
    # the OpenTofu management stack (Task 5) while this CronJob is applied by
    # Flux (Task 7), and nothing orders those two control planes against each
    # other. On a platform whose newest snapshot is the store of record, a
    # missing backup is far worse than a missing marker -- and the restore path
    # already has a branch for a snapshot that carries none.
    echo "${info}: Stamping ${CHECK_PATH} before the snapshot"
    # shellcheck disable=SC2046 # kv_ns_flag prints zero or one word by design
    if ! bao kv put $(kv_ns_flag) "${CHECK_PATH}" "value=$(date -u +%s)" >/dev/null; then
        echo "${warn}: could not write ${CHECK_PATH} -- the mount is missing, or this"
        echo "${warn}: role lacks create/update on it. Taking the snapshot anyway; it"
        echo "${warn}: will carry no freshness marker, so restoring it needs"
        echo "${warn}: --freshness warn."
    fi
    echo "${info}: Requesting a snapshot via ${VAULT_ADDR}"
    bao operator raft snapshot save "${SNAPSHOT_FILE}"
```

- [ ] **Step 6: Make the freshness check honour `--freshness` and stop re-stamping on restore**

Find, at the end of `restore()`:

```sh
    # The kv-v2 mount lives in the `app` tenant namespace, not root — platform
    # services are in root and tenants get namespaces. Without -namespace this
    # 404s.
    echo "${info}: Check that ${CHECK_NAMESPACE}/${CHECK_PATH} is less than ${NUM_DAYS} days old"
    CURR_TS=$(date "+%s")
    VAULT_TS=$(bao kv get -namespace="${CHECK_NAMESPACE}" --field=value "${CHECK_PATH}")

    if [ -z "${VAULT_TS}" ]; then
        echo "${err}: ${CHECK_PATH} is absent from the restored snapshot; cannot judge its age."
        exit 1
    fi

    if [ $((CURR_TS - VAULT_TS)) -gt $((NUM_DAYS * 86400)) ]; then
        echo "${err}: The restored snapshot is more than ${NUM_DAYS} days old."
        exit 1
    fi

    bao kv put -namespace="${CHECK_NAMESPACE}" "${CHECK_PATH}" "value=$(date "+%s")" >/dev/null 2>&1
}
```

Replace with:

```sh
    echo "${info}: Checking that ${CHECK_PATH} is less than ${NUM_DAYS} days old (--freshness ${FRESHNESS})"
    CURR_TS=$(date -u "+%s")

    # A READ FAILURE IS NOT AN ABSENT MARKER, and collapsing the two is the
    # mistake this file already argues against fifteen lines up, for bucket
    # listing: "keeps that failure loud and distinct from a genuinely empty
    # bucket". `2>/dev/null || true` would make permission-denied, mount-absent,
    # network-down, token-expired and genuinely-absent indistinguishable -- so
    # under --freshness warn a misconfigured read would silently mean "no
    # marker, carry on" and the guard could never fire. Fail open on purpose is
    # one thing; failing open by accident is another.
    kv_err="${HOME:-/tmp}/.kvget.$$"
    # shellcheck disable=SC2046 # kv_ns_flag prints zero or one word by design
    if VAULT_TS=$(bao kv get $(kv_ns_flag) --field=value "${CHECK_PATH}" 2>"${kv_err}"); then
        :
    elif grep -qi 'no value found\|not found' "${kv_err}"; then
        VAULT_TS=""
    else
        echo "${err}: could not READ ${CHECK_PATH}. This is a read failure, not an"
        echo "${err}: absent marker -- the mount may be missing, or this token may"
        echo "${err}: lack read on it. The snapshot HAS already been restored."
        cat "${kv_err}" >&2
        rm -f "${kv_err}"
        exit 1
    fi
    rm -f "${kv_err}"

    if [ -z "${VAULT_TS}" ]; then
        if [ "${FRESHNESS}" = "fail" ]; then
            echo "${err}: ${CHECK_PATH} is absent from the restored snapshot; cannot judge its age."
            exit 1
        fi
        echo "${warn}: ${CHECK_PATH} is absent from the restored snapshot (one taken before save() stamped it, or taken while the mount did not exist). Continuing."
        VAULT_TS=""
    fi

    # Guard the arithmetic: a non-numeric value would abort even under
    # --freshness warn, with `bad number` from dash rather than anything a
    # reader could act on.
    case "${VAULT_TS}" in
        '') : ;;
        *[!0-9]*)
            echo "${warn}: ${CHECK_PATH} holds a non-numeric value; cannot judge age."
            VAULT_TS="" ;;
    esac

    if [ -n "${VAULT_TS}" ]; then
        AGE_DAYS=$(( (CURR_TS - VAULT_TS) / 86400 ))
        echo "${info}: The restored snapshot was taken ${AGE_DAYS} day(s) ago."
        if [ $((CURR_TS - VAULT_TS)) -gt $((NUM_DAYS * 86400)) ]; then
            if [ "${FRESHNESS}" = "fail" ]; then
                echo "${err}: The restored snapshot is more than ${NUM_DAYS} days old."
                exit 1
            fi
            echo "${warn}: The restored snapshot is more than ${NUM_DAYS} days old. Continuing (--freshness warn)."
        fi
    fi
    # No re-stamp here: the marker means "when the snapshot was taken", and
    # only save() knows that.
}
```

Note the restructure: the absent and non-numeric branches now fall through to a
single guarded arithmetic block rather than `return 0`-ing out of the function,
so anything appended to `restore()` later still runs on the rehydrate path.

- [ ] **Step 7: Fix the two places the usage text still says `-u`**

In `usage()`, replace both `-u https://bao.domain.tld:8200` with `-a https://bao.domain.tld:8200` (the flag has always been `-a`).

- [ ] **Step 6b: `restore()` must use the token it was given, and the file it was given**

Two defects in the pre-existing body of `restore()` that make the rehydrate path
non-functional. Both are found by reading, not running, but the consequence is
total: without this step the restore fails every single time.

**The pre-restore root-token mint cannot work on a rehydrate.** `restore()` calls
`authenticate` (which honours a caller-supplied `VAULT_TOKEN`) and then, before
any `bao` call that matters, overwrites it with
`VAULT_TOKEN=$(generate_root_token)`. That helper feeds the **lineage's** stored
recovery share to `bao operator generate-root` — but on a rehydrate the node in
front of us was just initialised with *fresh* throwaway shares, so the stored
share does not belong to it and the mint fails. The throwaway root token the
caller passed is already root on this node and already has everything
`sys/storage/raft/snapshot-force` needs. The *post*-restore mint is different and
must stay: after the restore the token store is the snapshot's, so the lineage's
recovery keys are then exactly the right input.

In `authenticate()`, in the branch that accepts a caller-supplied token, find:

```sh
    if [ -n "${VAULT_TOKEN:-}" ]; then
        echo "${info}: Using the token supplied in VAULT_TOKEN."
        export VAULT_TOKEN
        return 0
    fi
```

Replace with:

```sh
    if [ -n "${VAULT_TOKEN:-}" ]; then
        echo "${info}: Using the token supplied in VAULT_TOKEN."
        export VAULT_TOKEN
        # Recorded so restore() knows not to replace it with a token minted from
        # recovery keys that may not belong to the node in front of us.
        SUPPLIED_VAULT_TOKEN=1
        return 0
    fi
```

Then in `restore()`, find:

```sh
    VAULT_TOKEN=$(generate_root_token)
    export VAULT_TOKEN

    bao operator raft snapshot restore -force /tmp/bao.snap
```

Replace with:

```sh
    # The pre-restore mint exists for the JWT and AppRole paths, whose tokens
    # lack sys/storage/raft/snapshot-force. A caller-supplied token is already
    # root on this node -- and on a rehydrate it is the ONLY thing that is,
    # because the lineage's recovery keys belong to the snapshot we are about to
    # restore, not to the throwaway init we are restoring over.
    if [ -z "${SUPPLIED_VAULT_TOKEN:-}" ]; then
        VAULT_TOKEN=$(generate_root_token)
        export VAULT_TOKEN
    fi

    bao operator raft snapshot restore -force "${SNAPSHOT_FILE}"
```

**And `-s` was being ignored.** `restore()` validated `SNAPSHOT_FILE` as
required and then hardcoded `/tmp/bao.snap` for both the download and the
restore, never removing it — so the caller's private scratch path was created
and cleaned while the complete dataset stayed at a predictable name with the
ambient umask. It is barrier-encrypted and useless without the KMS key, so this
is hygiene rather than disclosure, but the code read as though it cleaned up and
did not. Find both download lines:

```sh
        gcloud storage cp "gs://${BUCKET_NAME}/${SNAP}" /tmp/bao.snap
    else
        aws s3 cp "s3://${BUCKET_NAME}/${SNAP}" /tmp/bao.snap
```

Replace with:

```sh
        gcloud storage cp "gs://${BUCKET_NAME}/${SNAP}" "${SNAPSHOT_FILE}"
    else
        aws s3 cp "s3://${BUCKET_NAME}/${SNAP}" "${SNAPSHOT_FILE}"
```

- [ ] **Step 6b-bis: `check_openbao_status` has the same standby blindness**

Third occurrence of one shape, so fix it at the last site too. `check_openbao_status`
polls for HTTP 200 from `/v1/sys/health`, which only the **active** node returns;
a standby answers 429. It runs right after `bao operator init`, through the NLB,
whose target group deliberately reports standbys as healthy — so in
`mode = "ha"` the poll can land on a standby and time out with "OpenBao is not
initialized, unsealed, or active" on a cluster that is entirely fine. Latent
today because the committed posture is single-node, real for the production
posture the design describes. In `check_openbao_status`, find:

```bash
        status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health")
```

Replace with:

```bash
        # standbyok, for the same reason as the two probes in rehydrate and
        # pre-destroy: a bare /v1/sys/health returns 200 only for the ACTIVE
        # node, and this poll goes through the NLB, which reports standbys as
        # healthy. In `ha` it would otherwise time out on a healthy cluster.
        status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health?standbyok=true&perfstandbyok=true")
```

Leave `init_openbao`'s own probe alone: it waits for **501** (uninitialised),
which every node returns before init regardless of role, so the query string
would change nothing there.

- [ ] **Step 6c: A pre-existing bug that makes every restore fail after the snapshot is already applied**

`generate_root_token()` has never worked, and nothing noticed because — as the
OpenBao page says in as many words — the restore path was never tested. This
design depends on it, so it is fixed here. Find:

```sh
    bao operator generate-root -init --format json | jq -cr '.nonce, .otp' > "$nonce_file"
    read -r VAULT_NONCE VAULT_OTP < "$nonce_file"
```

`jq -cr '.nonce, .otp'` emits the two values on **two lines**. `read -r A B`
consumes **one** line and splits it on whitespace, so `VAULT_NONCE` gets the
nonce and `VAULT_OTP` is always **empty**. `bao operator generate-root -decode`
then fails with `otp string is wrong length`. Demonstrate it in one line before
you fix it:

```bash
printf '{"nonce":"n1","otp":"otp1"}' | jq -cr '.nonce, .otp' > /tmp/nf
read -r A B < /tmp/nf; echo "nonce='$A' otp='$B'"   # otp='' -- empty
```

Because the *post*-restore mint runs unconditionally, this fails **after**
`bao operator raft snapshot restore -force` has already been applied, on every
rehydrate, on both clouds. Replace with:

```sh
    bao operator generate-root -init --format json | jq -cr '.nonce, .otp' > "$nonce_file"
    # One `read` PER LINE. `jq -cr '.nonce, .otp'` prints two lines, and a
    # single `read -r VAULT_NONCE VAULT_OTP` consumes only the first -- so the
    # OTP came out empty and `generate-root -decode` failed with "otp string is
    # wrong length", after the destructive restore had already run. Introduced
    # in #1844 and never caught, because nothing exercised this path.
    { read -r VAULT_NONCE; read -r VAULT_OTP; } < "$nonce_file"
```

- [ ] **Step 6d: `verify_pki_present` must not report a missing mount as a transport failure**

`curl -f` exits 22 for *any* non-2xx, so a 404 (the mount genuinely is not
there) is indistinguishable from a TLS-trust or reachability failure — and the
message asserts the second while the caller escalates it into "destroy and
redeploy". Capture the status code instead of relying on `-f`. In
`scripts/openbao-config.sh`'s `verify_pki_present`, replace the request and its
error branch with:

```bash
    local pem http_code
    # -w '%{http_code}', not -f: `curl -f` collapses every non-2xx into exit 22,
    # so a 404 -- which IS a missing mount, and the one case the caller may act
    # on -- looked identical to a TLS or network failure, which is never a
    # reason to destroy anything.
    pem=$(curl "${curl_args[@]}" -w '\n%{http_code}' "$OPENBAO_URL/v1/pki_private_issuer/ca/pem" 2>/dev/null || true)
    http_code=$(printf '%s' "$pem" | tail -n1)
    pem=$(printf '%s' "$pem" | sed '$d')

    case "$http_code" in
        200) ;;
        404)
            log_message "ERROR" "pki_private_issuer is not mounted on this node (HTTP 404)."
            return 1 ;;
        '')
            log_message "ERROR" "Could not reach $OPENBAO_URL at all -- TLS trust or the node itself, not the PKI mount."
            return 1 ;;
        *)
            log_message "ERROR" "pki_private_issuer/ca/pem returned HTTP ${http_code}. Not a missing mount: check TLS trust and that this node is unsealed."
            return 1 ;;
    esac
```

Remove `-fsS` from the `curl_args` initialiser and use `-sS` instead, or `-f`
will still short-circuit before the status code is read.

- [ ] **Step 7b: Two one-line hardening fixes on lines this task already touches**

The file's own prior art is that a root token must not reach argv, where
`/proc/<pid>/cmdline` and `ps` expose it to anything in the same PID namespace.
Two places still break that rule, and both sit inside functions this task
rewrites, so fix them here rather than leaving a file that argues one thing and
does another.

In `generate_root_token()`, find:

```sh
    nonce_file="$HOME/.generate-root.$$"
```

Replace with:

```sh
    # 0077 before creating it: with HOME now being the operator's real home on
    # a non-container run, this file (the generate-root nonce and OTP) would
    # otherwise be created with the ambient umask.
    nonce_file="$HOME/.generate-root.$$"
    ( umask 077; : > "$nonce_file" )
```

In `restore()`, find:

```sh
    trap 'bao token revoke "${VAULT_TOKEN}" >/dev/null 2>&1 || true' EXIT
```

Replace with:

```sh
    # `-self` rather than passing the token as an argument: same job, nothing
    # on the command line.
    trap 'bao token revoke -self >/dev/null 2>&1 || true' EXIT
```

- [ ] **Step 8: Bump the image version**

Nothing to sync: `scripts/openbao-snapshot.sh` is a symlink to the file you just
edited, so the two paths are one inode. (`cp` between them exits 1 with
`are identical (not copied)`.) Confirm the symlink is intact rather than
replaced by a regular file — an editor that writes through the link would break
the invariant:

```bash
git ls-files -s scripts/openbao-snapshot.sh   # expect mode 120000
```

In `container-images/openbao-snapshot/Dockerfile`, directly after the line `FROM debian:bookworm-slim`, add:

```dockerfile

# The image's own version. `.github/workflows/build-container-images.yml` reads
# `ARG OPENBAO_SNAPSHOT_VERSION=` (the directory name upper-cased + _VERSION) and
# tags the image with it, so the CronJob can pin a real version instead of
# `latest`. Bump it whenever openbao-snapshot.sh changes behaviour.
ARG OPENBAO_SNAPSHOT_VERSION=v0.2.0
```

- [ ] **Step 9: Lint**

Run: `shellcheck -s sh scripts/openbao-snapshot.sh && diff -q scripts/openbao-snapshot.sh container-images/openbao-snapshot/openbao-snapshot.sh && echo OK`
Expected: `OK` (no shellcheck output).

- [ ] **Step 10: Smoke-test the parser offline**

Run:

```bash
sh scripts/openbao-snapshot.sh restore -a https://x:8200 -s /tmp/x -b b -f bogus; echo "exit=$?"
```

Expected: last lines `ERROR: --freshness must be 'fail' or 'warn', got 'bogus'.` … `exit=1`.

Run:

```bash
unset VAULT_TOKEN OPENBAO_JWT_PATH APPROLE_ROLE_ID APPROLE_SECRET_ID
CLOUD=aws sh -c '. /dev/stdin' <<'EOF'
# Source only the functions: stub the binaries the script checks for.
PATH="/tmp/fakebin:$PATH"; mkdir -p /tmp/fakebin; for b in bao jq aws; do printf '#!/bin/sh\nexit 0\n' > /tmp/fakebin/$b; chmod +x /tmp/fakebin/$b; done
sh scripts/openbao-snapshot.sh save -a https://x:8200 -s /tmp/x -b b; echo "exit=$?"
EOF
```

Expected: `ERROR: No OpenBao credentials. Set one of:` … `exit=1`. Then `rm -rf /tmp/fakebin`.

- [ ] **Step 11: Commit**

```bash
git add scripts/openbao-snapshot.sh container-images/openbao-snapshot/openbao-snapshot.sh container-images/openbao-snapshot/Dockerfile
git commit -m "feat(openbao): snapshot script accepts VAULT_TOKEN or a cluster JWT, stamps the marker on save

Three auth modes (VAULT_TOKEN, JWT via OPENBAO_JWT_*, AppRole), a
--freshness warn|fail switch for restores into an empty node, the marker
moved to the root-namespace lineage/ mount and written by save() so a
lineage's first snapshot is judgeable, and HOME only overridden when
/snapshot exists. Image version 0.2.0."
```

---

### Task 2: `openbao-config.sh` — `rehydrate` and `pre-destroy-snapshot`

**Files:**
- Modify: `scripts/openbao-config.sh`

- [ ] **Step 1: New options and usage**

In the option variable block after `PROJECT=""` add:

```bash
SNAPSHOT_BUCKET=""
CA_FILE=""
FRESHNESS_DAYS=8
```

In `usage()`, after the `  ca            Write the CA chain ...` line add:

```bash
    echo "  rehydrate     Initialise a fresh node and restore the lineage's newest snapshot"
    echo "                (falls back to a plain init when the bucket holds none)"
    echo "  pre-destroy-snapshot"
    echo "                Take one last snapshot before the cluster stack is destroyed"
```

In the options list, after the `--project` line add:

```bash
    echo "  --snapshot-bucket <Name>                  S3 bucket (aws) or GCS bucket (gcp) holding raft snapshots"
    echo "                                             (required for rehydrate and pre-destroy-snapshot)"
    echo "  --ca-file <Path>                          CA chain to verify the server with (sets VAULT_CACERT)"
    echo "  --freshness-days <N>                      Age past which a restored snapshot is reported as old (default: ${FRESHNESS_DAYS})"
```

In `parse_args()`'s `case`, after the `--project)` line add:

```bash
            --snapshot-bucket)            SNAPSHOT_BUCKET="$2"; shift 2 ;;
            --ca-file)                    CA_FILE="$2"; shift 2 ;;
            --freshness-days)             FRESHNESS_DAYS="$2"; shift 2 ;;
```

Find:

```bash
    if [ "$COMMAND" = "init" ]; then
```

Replace with:

```bash
    if [ "$COMMAND" = "init" ] || [ "$COMMAND" = "rehydrate" ]; then
```

After that whole `if ... fi` block (the one validating `--url`, root token and recovery keys for init) add:

```bash
    if [ "$COMMAND" = "rehydrate" ] || [ "$COMMAND" = "pre-destroy-snapshot" ]; then
        if [ -z "$SNAPSHOT_BUCKET" ]; then
            echo "--snapshot-bucket is required for $COMMAND"; usage; exit 1
        fi
    fi
    if [ "$COMMAND" = "pre-destroy-snapshot" ]; then
        if [ -z "$OPENBAO_URL" ] || [ -z "$ROOT_TOKEN_SECRET_NAME" ]; then
            echo "--url and --root-token-secret-name are required for pre-destroy-snapshot"; usage; exit 1
        fi
    fi
```

Find:

```bash
    export VAULT_ADDR="$OPENBAO_URL"
    if [ "$SKIP_VERIFY" = true ]; then
        export VAULT_SKIP_VERIFY=true
    fi
```

Replace with:

```bash
    export VAULT_ADDR="$OPENBAO_URL"
    if [ "$SKIP_VERIFY" = true ]; then
        export VAULT_SKIP_VERIFY=true
    fi
    if [ -n "$CA_FILE" ]; then
        if [ ! -r "$CA_FILE" ]; then
            echo "Error: --ca-file $CA_FILE is not readable (run the 'ca' subcommand first)" >&2
            exit 1
        fi
        export VAULT_CACERT="$CA_FILE"
    fi
```

- [ ] **Step 2: Helpers shared by the two new subcommands**

Add these functions after `secret_read()`:

```bash
# Environment the sibling snapshot script needs. It is POSIX sh and calls the
# cloud CLIs bare, so the region/profile/ADC choices made here have to reach it
# through the environment rather than flags.
export_snapshot_env() {
    export CLOUD
    if [ "$CLOUD" = "aws" ]; then
        # BOTH, and in this order of precedence: the AWS CLI resolves AWS_REGION
        # ahead of AWS_DEFAULT_REGION, so exporting only the latter lets an
        # AWS_REGION already in the operator's shell send the child to a
        # different region than the parent's own --region calls use -- a region
        # split inside one operation.
        export AWS_REGION="$REGION"
        export AWS_DEFAULT_REGION="$REGION"
        # Deliberately not exported when empty: that leaves an inherited
        # AWS_PROFILE alone, matching get_aws_cmd's behaviour.
        if [ -n "$PROFILE" ]; then export AWS_PROFILE="$PROFILE"; fi
    else
        export CLOUDSDK_CORE_PROJECT="$PROJECT"
        # Reuse the library rather than re-resolving the token. It caches, it
        # reports which identity is in play, and -- the reason this is not
        # inlined -- a local variable here would be DYNAMICALLY SCOPED over the
        # caller's: pre_destroy_snapshot declares `local token` and fills it
        # with the lineage root token before calling this function, and an
        # assignment plus `unset token` in here would destroy it, handing the
        # child an empty VAULT_TOKEN. Measured in bash 5.3.
        if [ -z "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}" ]; then
            local adc_token
            if adc_token=$(gcloud auth application-default print-access-token 2>/dev/null) && [ -n "$adc_token" ]; then
                export CLOUDSDK_AUTH_ACCESS_TOKEN="$adc_token"
            fi
        fi
    fi
}

# Newest snapshot object in the lineage bucket.
#
#   stdout = the object name, or EMPTY when the bucket genuinely holds none
#   return = 0 on a successful listing, 1 when the listing itself FAILED
#
# The two must not be conflated, and conflating them is the single most
# dangerous mistake available in this file. An empty answer routes the caller
# to "first deploy of this lineage -> plain init", which WRITES a fresh root
# token and fresh recovery keys over the lineage's. Reaching that from an
# expired session or a mistyped --profile, while the bucket still holds every
# snapshot, produces an OpenBao whose stored recovery keys no longer match any
# snapshot -- discovered during an incident.
#
# The sibling script already argues this at length for its own listing
# (container-images/openbao-snapshot/openbao-snapshot.sh, `restore`): "this is a
# listing failure, NOT an empty bucket". Same rule here.
latest_snapshot() {
    if [ "$CLOUD" = "gcp" ]; then
        local listing
        if ! listing=$(gcp_gcloud storage ls "gs://${SNAPSHOT_BUCKET}/"); then
            log_message "ERROR" "could not list gs://${SNAPSHOT_BUCKET} -- a listing failure, NOT an empty bucket."
            return 1
        fi
        # `grep || true`: grep exits 1 when it matches nothing, and this file
        # runs with `set -o pipefail`, so an unguarded grep in a pipeline turns
        # a legitimately empty bucket into a hard failure.
        printf '%s\n' "$listing" | sed 's#.*/##' | { grep '\.snap$' || true; } | sort | tail -n1
    else
        local aws_cmd; aws_cmd=$(get_aws_cmd)
        local out
        # Full JSON, filtered by jq, rather than --query sort_by(...)[-1]: that
        # query ERRORS on an empty bucket, so exit status alone could not
        # separate "empty" from "could not list".
        if ! out=$($aws_cmd s3api list-objects-v2 --bucket "$SNAPSHOT_BUCKET" --output json); then
            log_message "ERROR" "could not list s3://${SNAPSHOT_BUCKET} -- a listing failure, NOT an empty bucket."
            return 1
        fi
        printf '%s' "$out" | jq -r '(.Contents // []) | if length == 0 then "" else (sort_by(.LastModified) | last | .Key) end'
    fi
}

# The PKI mount's CA endpoint is unauthenticated, which makes it the one thing a
# rehydrate can assert without a token: if it answers with a certificate that
# chains to the CA we already trust, the barrier unwrapped and the mount came
# back.
verify_pki_present() {
    # argv built as an ARRAY. `"${VAULT_CACERT:+--cacert $VAULT_CACERT}"` looks
    # right and is not: quoted, it passes `--cacert /path` as ONE argv element
    # ("option --cacert /path: is unknown"), and when the variable is unset it
    # passes an empty word ("blank argument where content is expected"). Either
    # way curl exits 2 on every run and this function reports a missing PKI
    # mount that is actually present -- the most misleading message this script
    # can produce, on the disaster-recovery path. Measured, both states.
    local -a curl_args=(-fsS)
    if [ -n "${VAULT_CACERT:-}" ]; then curl_args+=(--cacert "$VAULT_CACERT"); fi
    if [ -n "${VAULT_SKIP_VERIFY:-}" ]; then curl_args+=(-k); fi

    local pem
    if ! pem=$(curl "${curl_args[@]}" "$OPENBAO_URL/v1/pki_private_issuer/ca/pem"); then
        log_message "ERROR" "pki_private_issuer/ca/pem did not answer. The transport failed, so this could be TLS trust or an unreachable node -- not necessarily a missing mount."
        return 1
    fi
    if ! printf '%s\n' "$pem" | openssl x509 -noout -subject >/dev/null 2>&1; then
        log_message "ERROR" "pki_private_issuer/ca/pem returned something that is not a certificate"
        return 1
    fi
    log_message "INFO" "PKI issuer present: $(printf '%s\n' "$pem" | openssl x509 -noout -subject)"

    # Chain it to the CA we were given, which makes this the assertion the
    # design actually promises ("issuer chains to the offline root") rather than
    # just "the bytes parse". Skipped when no --ca-file was passed, since there
    # is then nothing to verify against.
    if [ -n "${VAULT_CACERT:-}" ]; then
        if ! printf '%s\n' "$pem" | openssl verify -CAfile "$VAULT_CACERT" >/dev/null 2>&1; then
            log_message "ERROR" "the restored PKI issuer does NOT chain to ${VAULT_CACERT}. The mount came back, but under a different root than this lineage's."
            return 1
        fi
        log_message "INFO" "PKI issuer chains to ${VAULT_CACERT}."
    fi
}
```

The token is resolved directly rather than through the library, and that is not an
oversight: `scripts/lib/gcloud-adc.sh` exposes only `gcp_gcloud` and
`gcp_gcloud_identity` (verified 2026-09-02 — its token lives in a private
`_gcloud_adc_token`, with no accessor). So this one call duplicates what the
library does internally. What must not be duplicated is the *variable*: it is
declared `local`, because a bare `token=` here is dynamically scoped over the
caller's and destroyed `pre_destroy_snapshot`'s root token.

- [ ] **Step 3: The `rehydrate` subcommand**

Add after `init_openbao()`:

```bash
# Rehydrate a freshly booted, uninitialised node from the lineage's newest
# snapshot. This is what makes OpenBao's storage a derived artefact: the
# durable copy is the snapshot in the lineage bucket, sealed by the lineage's
# KMS key, and the running process is rebuilt from it on every deploy.
#
# Three rules, in code below and in the design:
#   1. The throwaway root token and recovery shares from `operator init` are
#      NEVER written to the secret store. The restore replaces them with the
#      snapshot's, which are the ones already stored.
#   2. Idempotent: a node that is already initialised and unsealed is left alone.
#   3. The freshness guard is `warn`, not `fail`: there is no populated cluster
#      to protect, so age is information here.
#
# `bao operator init` is the point of no return -- after it, the node holds keys
# nobody has -- so everything checkable happens BEFORE it.
rehydrate_openbao() {
    if ! wait_for_openbao; then
        log_message "ERROR" "Failed to wait for OpenBao to be ready"
        exit 1
    fi

    # `?standbyok=true&perfstandbyok=true`, matching the NLB's own target-group
    # check. A bare /v1/sys/health returns 200 only for initialized + unsealed
    # + ACTIVE; a standby answers 429. The URL here goes through the NLB, whose
    # target group deliberately flattens standby into healthy, so in
    # `mode = "ha"` the probe can land on a standby -- and a bare check would
    # then refuse the operation with "not active (HTTP 429)" on a perfectly
    # healthy cluster.
    status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health?standbyok=true&perfstandbyok=true" || true)
    case "$status_code" in
        200)
            # Initialised and unsealed -- but that is also exactly what a node
            # left behind by a FAILED restore looks like: throwaway keys, no
            # lineage data. Exiting 0 on the strength of a 200 alone would turn
            # a loud failure into a silent success on the next deploy, and the
            # management stack would then run against an empty store.
            if verify_pki_present; then
                log_message "INFO" "OpenBao is already initialized, unsealed, and holds the PKI -- nothing to rehydrate"
                exit 0
            fi
            # No PKI. Two very different situations look identical from here,
            # and the BUCKET is what separates them:
            #
            #   bucket has a snapshot -> this node should have restored it and
            #                            did not. Stranded: throwaway keys
            #                            nobody holds.
            #   bucket is empty       -> a young lineage part-way through its
            #                            FIRST bootstrap. `init_openbao` has
            #                            run and stored real keys, and the PKI
            #                            mount does not exist yet because the
            #                            `tofu apply` that creates it has not
            #                            succeeded yet. Perfectly recoverable:
            #                            just let this deploy continue.
            #
            # Getting this wrong in the safe-looking direction is expensive: it
            # tells an operator whose apply merely failed to destroy a cluster
            # holding freshly stored keys.
            export_snapshot_env
            # `local` on its own line, then assign: `local x=$(cmd)` masks the
            # command's exit status behind local's own.
            local _latest
            if ! _latest=$(latest_snapshot); then
                log_message "ERROR" "OpenBao has no PKI mount and the lineage bucket cannot be listed, so this"
                log_message "ERROR" "cannot be told apart from a failed restore. Fix the listing and re-run."
                exit 1
            fi
            if [ -z "$_latest" ]; then
                log_message "WARN" "OpenBao is initialized and unsealed with no PKI mount, and ${SNAPSHOT_BUCKET} is"
                log_message "WARN" "empty -- a first bootstrap whose 'tofu apply' has not completed. Continuing;"
                log_message "WARN" "the apply after this step is what creates the PKI."
                exit 0
            fi
            log_message "ERROR" "OpenBao is initialized and unsealed but has NO PKI mount, while ${SNAPSHOT_BUCKET}"
            log_message "ERROR" "holds ${_latest}. This is the state a failed restore leaves behind: the node holds"
            log_message "ERROR" "throwaway keys that were never stored, so nothing can authenticate to it. Destroy"
            log_message "ERROR" "and redeploy the cluster stack with TM_OPENBAO_SKIP_SNAPSHOT=true -- there is"
            log_message "ERROR" "nothing on this node worth snapshotting."
            exit 1 ;;
        501) ;;
        *)
            log_message "ERROR" "Unexpected status code: $status_code"
            exit 1 ;;
    esac

    export_snapshot_env

    # Distinguish "the bucket is empty" from "we could not read the bucket".
    # Only the first may proceed to a plain init, because a plain init OVERWRITES
    # the lineage's stored root token and recovery keys. Getting there from an
    # expired session, while the bucket still holds every snapshot, is how a
    # lineage becomes unrecoverable.
    local latest
    if ! latest=$(latest_snapshot); then
        log_message "ERROR" "Refusing to initialise: cannot prove ${SNAPSHOT_BUCKET} is empty."
        log_message "ERROR" "Initialising now would overwrite this lineage's stored root token and"
        log_message "ERROR" "recovery keys. Fix the listing (credentials, region, bucket name) and re-run."
        exit 1
    fi

    if [ -z "$latest" ]; then
        log_message "INFO" "No snapshot in ${SNAPSHOT_BUCKET}: first deploy of this lineage. Initialising and storing the new keys."
        init_openbao
        return 0
    fi

    # Pre-flight, all of it before the irreversible init. Each of these used to
    # be discovered only afterwards, stranding the node.
    if ! echo "$FRESHNESS_DAYS" | grep -Eq '^[0-9]+$'; then
        log_message "ERROR" "--freshness-days must be a positive integer (got '${FRESHNESS_DAYS}')"
        exit 1
    fi
    for bin in openssl curl; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            log_message "ERROR" "$bin is required by the restore path and is not installed"
            exit 1
        fi
    done
    if ! secret_read "$RECOVERY_KEYS_SECRET_NAME" >/dev/null 2>&1; then
        log_message "ERROR" "Cannot read ${RECOVERY_KEYS_SECRET_NAME}. The restore mints a root token from it,"
        log_message "ERROR" "so refusing before the init rather than stranding the node afterwards."
        exit 1
    fi

    log_message "INFO" "Snapshot ${latest} found in ${SNAPSHOT_BUCKET}. Initialising with throwaway shares, then restoring."

    local scratch
    scratch=$(mktemp -d)
    # DOUBLE quotes, so $scratch is expanded NOW, when the trap is set -- not
    # when it fires. With single quotes the expansion happens at fire time, by
    # which point a SUCCESS path has already returned and the local is out of
    # scope: `set -u` then makes the trap itself fatal, so the function returns
    # 1 after doing its job correctly, AND the directory is never removed.
    # Failure paths are unaffected (the frame is still live when `exit` fires
    # the trap), so the bug is invisible to any test that exercises an error.
    # Measured on bash 3.2 and 5.3. `mktemp -d` output contains no quotes, so
    # embedding it is safe. INT/TERM exit explicitly, or bash runs the handler
    # and resumes.
    trap "rm -rf -- '$scratch'" EXIT
    trap "rm -rf -- '$scratch'; exit 130" INT TERM

    local init_output root_token
    init_output=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
    root_token=$(printf '%s' "$init_output" | jq -r '.root_token // empty')
    unset init_output
    if [ -z "$root_token" ]; then
        log_message "ERROR" "operator init returned no root token"
        exit 1
    fi

    if ! check_openbao_status; then
        log_message "ERROR" "Node did not become active after init"
        exit 1
    fi

    # VAULT_TOKEN is the throwaway root token, and it is what performs the
    # restore: it is the only credential that exists on this node. The
    # LINEAGE's recovery keys are passed too, because the child needs them
    # AFTER the restore, once the snapshot's token store has replaced the
    # throwaway one.
    if ! VAULT_TOKEN="$root_token" RECOVERY_KEYS_SECRET_ID="$RECOVERY_KEYS_SECRET_NAME" \
        sh "$(dirname "$0")/openbao-snapshot.sh" restore \
            -a "$OPENBAO_URL" -b "$SNAPSHOT_BUCKET" -s "$scratch/bao.snap" \
            -d "$FRESHNESS_DAYS" --freshness warn; then
        log_message "ERROR" "Restore failed. The node is initialised with THROWAWAY keys that were never stored,"
        log_message "ERROR" "so nothing can authenticate to it. Destroy and redeploy the cluster stack; the"
        log_message "ERROR" "pre-destroy snapshot will refuse (no usable token), so pass"
        log_message "ERROR" "TM_OPENBAO_SKIP_SNAPSHOT=true -- there is nothing here worth snapshotting."
        exit 1
    fi
    unset root_token

    if ! verify_pki_present; then
        exit 1
    fi
    # Deliberately not naming ${latest}: the child re-lists and selects
    # independently, so its own "Restoring snapshot ..." line is the
    # authoritative one and this must not contradict it.
    log_message "INFO" "Rehydrate complete; see the restore output above for the snapshot used."
}
```

- [ ] **Step 4: The `pre-destroy-snapshot` subcommand**

Add after `rehydrate_openbao()`:

```bash
# One last snapshot before `tofu destroy` takes the node away. Runs from the
# operator's context with the lineage root token: the in-cluster CronJob cannot
# do this because `--reverse destroy` has already removed the cluster it ran in.
#
# Fails hard when OpenBao is unreachable, because destroying anyway loses every
# write since the last scheduled snapshot. TM_OPENBAO_SKIP_SNAPSHOT=true is the
# explicit override for a node that is already gone.
pre_destroy_snapshot() {
    if [ "${TM_OPENBAO_SKIP_SNAPSHOT:-false}" = "true" ]; then
        log_message "WARN" "TM_OPENBAO_SKIP_SNAPSHOT=true -- skipping the pre-destroy snapshot"
        exit 0
    fi

    # `?standbyok=true&perfstandbyok=true`, matching the NLB's own target-group
    # check. A bare /v1/sys/health returns 200 only for initialized + unsealed
    # + ACTIVE; a standby answers 429. The URL here goes through the NLB, whose
    # target group deliberately flattens standby into healthy, so in
    # `mode = "ha"` the probe can land on a standby -- and a bare check would
    # then refuse the operation with "not active (HTTP 429)" on a perfectly
    # healthy cluster.
    status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health?standbyok=true&perfstandbyok=true" || true)
    if [ "$status_code" != "200" ]; then
        log_message "ERROR" "OpenBao at $OPENBAO_URL is not active (HTTP ${status_code:-none}); refusing to destroy without a snapshot."
        log_message "ERROR" "If the node is genuinely gone, re-run with TM_OPENBAO_SKIP_SNAPSHOT=true."
        exit 1
    fi

    # `export_snapshot_env` FIRST, then read the token. Order matters: that
    # function must not be able to touch this scope's `token`, and while it now
    # declares its own local, doing the read afterwards means a future edit to
    # it cannot reintroduce the clobber. (It did clobber it: bash is dynamically
    # scoped, so its non-local `token` assignment plus `unset token` destroyed
    # this one, and the child was handed an empty VAULT_TOKEN -- so a GCP
    # destroy could never take its final snapshot.)
    export_snapshot_env

    local root_token
    if ! root_token=$(secret_read "$ROOT_TOKEN_SECRET_NAME" | jq -r '.token // empty') || [ -z "$root_token" ]; then
        log_message "ERROR" "Could not read the root token from $ROOT_TOKEN_SECRET_NAME"
        exit 1
    fi

    local scratch
    scratch=$(mktemp -d)
    # Double-quoted for the same reason as in rehydrate_openbao: expanded at
    # set time, or a SUCCESSFUL snapshot returns 1 from the trap and leaves the
    # directory behind. That failure is worse here than it looks -- the destroy
    # workflow reads the non-zero status as 'snapshot failed' and blocks, and
    # the operator's documented escape is TM_OPENBAO_SKIP_SNAPSHOT=true, i.e.
    # destroying WITHOUT a snapshot: the exact loss this function exists to
    # prevent.
    trap "rm -rf -- '$scratch'" EXIT
    trap "rm -rf -- '$scratch'; exit 130" INT TERM

    if ! VAULT_TOKEN="$root_token" sh "$(dirname "$0")/openbao-snapshot.sh" save \
            -a "$OPENBAO_URL" -b "$SNAPSHOT_BUCKET" -s "$scratch/bao.snap"; then
        log_message "ERROR" "Pre-destroy snapshot failed; not destroying."
        exit 1
    fi
    unset root_token
    log_message "INFO" "Pre-destroy snapshot stored in ${SNAPSHOT_BUCKET}."
}
```

The local is named `root_token`, not `token`, for the same reason: `token` is the
name the ADC helper historically used, and a collision here is silent.

- [ ] **Step 5: Wire the subcommands**

In the `case "$COMMAND"` at the bottom, before `    *)`, add:

```bash
    rehydrate)
        parse_args "$@"
        check_prerequisites
        rehydrate_openbao
        ;;
    pre-destroy-snapshot)
        parse_args "$@"
        check_prerequisites
        # The CA is fetched by the caller (`ca` subcommand) so VAULT_CACERT can be
        # set; --skip-verify is the fallback for a first bootstrap.
        pre_destroy_snapshot
        ;;
```

- [ ] **Step 6: Lint and parser checks**

Run: `shellcheck -x -S warning scripts/openbao-config.sh; echo "exit=$?"`
Expected: `exit=0`. These are CI's flags (`.github/workflows/ci.yaml:212`). Plain
`shellcheck` without them exits 1 on a pre-existing info-level `SC1091` about the
`lib/gcloud-adc.sh` source line, which is not a defect in this task.

Run: `bash scripts/openbao-config.sh rehydrate --url https://x:8200 --root-token-secret-name a --recovery-keys-secret-name b; echo "exit=$?"`
Expected: `--snapshot-bucket is required for rehydrate` then usage, `exit=1`.

Run: `bash scripts/openbao-config.sh pre-destroy-snapshot --snapshot-bucket b; echo "exit=$?"`
Expected: `--url and --root-token-secret-name are required for pre-destroy-snapshot`, `exit=1`.

**Then three stub-driven checks, because `shellcheck` and the argument parser
cannot reach any of the code that matters.** An earlier revision of this task
shipped four Critical defects that all three of these would have caught, with no
cluster and no credentials. Write the stubs into a scratch directory on `PATH`,
run each check, and report the transcript.

*(a) A failed listing must never lead to an init.* Stub `aws` and `gcloud` to
exit 1, stub `bao` and `jq` so nothing else fails first, then:

```bash
bash scripts/openbao-config.sh rehydrate --url https://127.0.0.1:1 \
  --root-token-secret-name a --recovery-keys-secret-name b --snapshot-bucket bkt
```

Expected: it refuses with `cannot prove ... is empty` and a non-zero exit, and
**`bao operator init` is never invoked** — have the `bao` stub append its
arguments to a log and show the log contains no `operator init`. If the run
instead reports "first deploy of this lineage", the C1 defect is back.

*(b) A genuinely empty bucket must reach the init path.* Same stubs, but with
`aws`/`gcloud` exiting 0 and printing an empty listing (`{"Contents":[]}` for
`s3api list-objects-v2 --output json`; nothing for `gcloud storage ls`). Expected:
the run reaches `No snapshot in ... first deploy of this lineage`. Check the GCP
branch too (`--cloud gcp --project p`): `grep` matching nothing under `pipefail`
is exactly what used to abort the first GCP deploy with no output at all.

*(c) `verify_pki_present` must actually work.* Call it directly, both with and
without a CA file, against any HTTPS URL:

```bash
bash -c 'set -euo pipefail; . scripts/lib/gcloud-adc.sh
         OPENBAO_URL=https://example.com; VAULT_CACERT=""; source_only=1
         # paste or source the function, then:
         verify_pki_present; echo "exit=$?"'
```

You will need to source the function without running the script's dispatch — the
simplest way is `sed -n '/^verify_pki_present()/,/^}/p' scripts/openbao-config.sh > /tmp/f.sh`
and source that alongside a stub `log_message`. Expected: a clean transport error
about the endpoint, **not** `curl: option --cacert ...: is unknown` and **not**
`curl: option : blank argument where content is expected`. Either of those means
the argv is being built as a single word again.

*(d) The trap must not turn success into failure, and must clean up.* Both
`rehydrate` and `pre-destroy-snapshot` create a scratch dir and remove it on a
trap. Run each to a **successful** completion under stubs and assert two things:
the exit status is **0**, and the `mktemp -d` directory is gone. This is the
check that a failure-only test cannot make — the trap works on every error path
and breaks only on success, because the local it expands has gone out of scope
by the time it fires.

*(e) The root-token mint must receive a non-empty OTP.* Stub `bao` so that
`operator generate-root -decode` **asserts** its `-otp` argument is non-empty
and fails loudly otherwise, then drive `restore` to the point of the mint.
Expected: the assertion passes. Before Step 6c's fix it fails with an empty
`-otp`, which is how a broken restore survived a review that only read the code.

Delete the stub directory afterwards.

- [ ] **Step 7: Commit**

```bash
git add scripts/openbao-config.sh
git commit -m "feat(openbao): rehydrate and pre-destroy-snapshot subcommands

rehydrate initialises a fresh node with throwaway shares it never stores,
restores the lineage's newest snapshot with the freshness guard in warn
mode, and asserts the PKI issuer answers. pre-destroy-snapshot takes a
last snapshot with the lineage root token before the cluster stack goes,
refusing to proceed when OpenBao is unreachable unless
TM_OPENBAO_SKIP_SNAPSHOT=true."
```

---

### Task 3: AWS lineage stack

**Files:**
- Create: `opentofu/aws/openbao/lineage/stack.tm.hcl`
- Create: `opentofu/aws/openbao/lineage/backend.tf`
- Create: `opentofu/aws/openbao/lineage/versions.tf`
- Create: `opentofu/aws/openbao/lineage/providers.tf`
- Create: `opentofu/aws/openbao/lineage/variables.tf`
- Create: `opentofu/aws/openbao/lineage/variables.tfvars`
- Create: `opentofu/aws/openbao/lineage/kms.tf`
- Create: `opentofu/aws/openbao/lineage/s3.tf`
- Create: `opentofu/aws/openbao/lineage/github-oidc.tf`
- Create: `opentofu/aws/openbao/lineage/outputs.tf`
- Create: `opentofu/aws/openbao/lineage/workflows.tm.hcl`
- Create: `opentofu/aws/openbao/lineage/.trivyignore.yaml`
- Delete: `security/aws-0/openbao-snapshot/kms.yaml`, `security/aws-0/openbao-snapshot/s3-bucket.yaml`
- Modify: `security/aws-0/openbao-snapshot/kustomization.yaml`

Why the bucket and its key leave Crossplane: rehydrate needs the bucket to exist *before* the cluster that used to create it. The Crossplane MRs carry no `Delete` management policy, so deleting the manifests orphans the AWS objects; Task 15 imports them into this stack.

- [ ] **Step 1: `stack.tm.hcl`**

```hcl
stack {
  name        = "OpenBao lineage"
  description = "What a rebuilt OpenBao needs to come back: the multi-region seal key, the snapshot bucket and its key, and the CI drill role. Persistent -- never destroyed by the default destroy script"
  id          = "5ca47693-4f30-47b3-a551-7bc20df9a40d"

  # No `after`: nothing here depends on the network. openbao/cluster lists this
  # stack in ITS `after`, which is the edge that matters.

  tags = [
    "aws",
    "openbao",
    "openbao-lineage",
    "security",
    # Read by nothing today; names the class so `terramate list --tags=persistent`
    # answers "what survives a teardown by design".
    "persistent",
  ]
}
```

- [ ] **Step 2: `backend.tf`, `versions.tf`, `providers.tf`**

`backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/openbao/lineage/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true # native S3 locking (.tflock object, no DynamoDB)
  }
}
```

`versions.tf`:

```hcl
terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
```

`providers.tf`:

```hcl
provider "aws" {
  region = var.region
}

# The replica region for the multi-region seal key. A regional KMS outage in
# eu-west-3 must not take the seal with it, or the GCP standby could never
# unwrap the snapshot it restores -- see the design's "Cross-cloud fallback".
provider "aws" {
  alias  = "replica"
  region = var.replica_region
}
```

- [ ] **Step 3: `variables.tf` and `variables.tfvars`**

`variables.tf`:

```hcl
variable "region" {
  description = "Primary AWS region: where the seal key's primary and the snapshot bucket live"
  type        = string
  default     = "eu-west-3"
}

variable "replica_region" {
  description = "Second AWS region holding a replica of the multi-region seal key. Must differ from region."
  type        = string
  default     = "eu-west-1"

  validation {
    condition     = var.replica_region != var.region
    error_message = "replica_region must differ from region, or the replica buys nothing."
  }
}

variable "seal_key_alias" {
  description = "Alias of the seal key, in both regions. The cluster stack, the standby role and the drill role all reference the key through this alias."
  type        = string
  default     = "alias/openbao-seal"
}

variable "snapshot_bucket_name" {
  description = "S3 bucket holding raft snapshots. Empty derives <region>-ogenki-openbao-snapshot, the name the Crossplane-managed bucket already has."
  type        = string
  default     = ""
}

variable "snapshot_key_alias" {
  description = "Alias of the KMS key encrypting the snapshot bucket. Kept at the Crossplane-era name so the imported key keeps its alias."
  type        = string
  default     = "alias/xplane-openbao-snapshot"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose main-branch workflows may assume the drill role"
  type        = string
  default     = "Smana/cloud-native-ref"
}

variable "drill_role_name" {
  description = "IAM role the weekly restore drill assumes from GitHub Actions"
  type        = string
  default     = "openbao-restore-drill"
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    project = "cloud-native-ref"
    owner   = "Smana"
    app     = "openbao"
  }
}
```

`variables.tfvars`:

```hcl
# Everything is on its defaults in variables.tf. Present and tracked because a
# stack whose tfvars is gitignored cannot be deployed from a clean checkout.
region = "eu-west-3"
```

- [ ] **Step 4: `kms.tf`**

```hcl
# The seal key. This is THE asset: a snapshot without it is ciphertext.
#
# It used to live in opentofu/aws/openbao/cluster/kms.tf with a 10-day deletion
# window, so every rebuild minted a new key and every snapshot taken under the
# previous one became unreadable. Harmless while dev mode ran `file` storage
# and never took a snapshot; fatal for anything that restores one.
#
# Multi-region: the primary here, one replica in var.replica_region. A replica
# shares key material and key ID (`mrk-...`) with the primary, so ciphertext
# wrapped in eu-west-3 unwraps in eu-west-1. That is what lets a GCP standby,
# or a CI drill, restore a snapshot during a eu-west-3 outage.
#
# No custom key policy. The default policy delegates to IAM, and every grant
# on this key is an identity policy using the kms:ResourceAliases condition --
# a key policy naming role ARNs would refuse to apply until those roles exist,
# and two of them live in other stacks.
#trivy:ignore:AVD-AWS-0104
resource "aws_kms_key" "seal" {
  description             = "OpenBao seal key (lineage). Multi-region; replica in ${var.replica_region}"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "seal" {
  name          = var.seal_key_alias
  target_key_id = aws_kms_key.seal.key_id
}

resource "aws_kms_replica_key" "seal" {
  provider                = aws.replica
  description             = "OpenBao seal key (lineage) -- replica of ${var.region}"
  primary_key_arn         = aws_kms_key.seal.arn
  deletion_window_in_days = 30
  tags                    = var.tags
}

# Same alias name in the replica region, so a consumer only needs to know the
# alias and the region it is in.
resource "aws_kms_alias" "seal_replica" {
  provider      = aws.replica
  name          = var.seal_key_alias
  target_key_id = aws_kms_replica_key.seal.key_id
}
```

- [ ] **Step 5: `s3.tf`**

```hcl
# The snapshot bucket and its key, adopted from the Crossplane MRs that used to
# live in security/aws-0/openbao-snapshot/. Both are imported (Task 15), not
# recreated: the bucket already holds snapshots.
#
# Why they move: rehydrate reads this bucket BEFORE the cluster exists, and the
# GCS mirror (opentofu/gcp/openbao/lineage) pulls from it whether or not gcp-0
# has ever been built. A bucket created by a cluster cannot be a precondition
# of that cluster.

data "aws_caller_identity" "this" {}

locals {
  snapshot_bucket_name = var.snapshot_bucket_name == "" ? format("%s-ogenki-openbao-snapshot", var.region) : var.snapshot_bucket_name
}

#trivy:ignore:AVD-AWS-0104
resource "aws_kms_key" "snapshot" {
  description             = "Used for the Vault s3 bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "snapshot" {
  name          = var.snapshot_key_alias
  target_key_id = aws_kms_key.snapshot.key_id
}

resource "aws_s3_bucket" "snapshot" {
  bucket = local.snapshot_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "snapshot" {
  bucket                  = aws_s3_bucket.snapshot.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.snapshot.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# Versioning is new (the Crossplane bucket had none). It is what lets a
# snapshot overwritten by a bad run be recovered, and the lifecycle rule below
# keeps noncurrent versions from accumulating.
resource "aws_s3_bucket_versioning" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Same rules the Crossplane BucketLifecycleConfiguration applied: Glacier after
# 30 days, gone after 120.
resource "aws_s3_bucket_lifecycle_configuration" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id

  rule {
    id     = "glacier"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "GLACIER"
    }
  }

  rule {
    id     = "expiration"
    status = "Enabled"
    filter {}

    expiration {
      days = 120
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.snapshot]
}
```

- [ ] **Step 6: `github-oidc.tf`**

```hcl
# GitHub Actions -> AWS, for the weekly restore drill only.
#
# The drill starts an OpenBao with the lineage seal, restores the newest
# snapshot and asserts the PKI issuer answers. It therefore needs the seal key
# (encrypt at init, decrypt to unwrap), the bucket, and the bucket's key --
# and nothing else. In particular it does NOT get the recovery keys: the drill
# proves restorability through unauthenticated endpoints, and a CI runner
# holding the material that mints a root token would be a standing exposure.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

data "aws_iam_policy_document" "drill_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the scheduled/dispatched workflow on main. A pull request from a
    # fork carries a different sub and is refused.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "drill" {
  name               = var.drill_role_name
  description        = "Assumed by .github/workflows/openbao-restore-drill.yml to restore the newest OpenBao snapshot into a throwaway node"
  assume_role_policy = data.aws_iam_policy_document.drill_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "drill" {
  # By alias, not by ARN, in every region: the seal key is multi-region and
  # the drill may run against either copy. kms:ResourceAliases is multivalued,
  # hence ForAnyValue.
  statement {
    sid    = "SealAndBucketKeysByAlias"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["arn:aws:kms:*:${data.aws_caller_identity.this.account_id}:key/*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [var.seal_key_alias, var.snapshot_key_alias]
    }
  }

  statement {
    sid     = "ReadSnapshots"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.snapshot.arn,
      "${aws_s3_bucket.snapshot.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "drill" {
  name   = "openbao-restore-drill"
  role   = aws_iam_role.drill.id
  policy = data.aws_iam_policy_document.drill.json
}
```

- [ ] **Step 7: `outputs.tf`**

```hcl
output "seal_key_arn" {
  description = "Primary seal key ARN"
  value       = aws_kms_key.seal.arn
}

output "seal_key_id" {
  description = "Multi-region key ID (mrk-...), identical in both regions. What a standby's awskms seal stanza names."
  value       = aws_kms_key.seal.key_id
}

output "seal_key_alias" {
  description = "Alias present in both regions"
  value       = aws_kms_alias.seal.name
}

output "replica_region" {
  description = "Where the replica key lives"
  value       = var.replica_region
}

output "snapshot_bucket_name" {
  description = "Raft snapshot bucket"
  value       = aws_s3_bucket.snapshot.bucket
}

output "snapshot_bucket_arn" {
  description = "Raft snapshot bucket ARN, for policies in other stacks"
  value       = aws_s3_bucket.snapshot.arn
}

output "drill_role_arn" {
  description = "Set this as the AWS_DRILL_ROLE_ARN repository variable for the drill workflow"
  value       = aws_iam_role.drill.arn
}
```

- [ ] **Step 8: `workflows.tm.hcl` — destroy gate**

```hcl
# Lineage stacks are what survive a teardown BY DESIGN. Only `destroy` is
# overridden; deploy / preview / drift inherit the global scripts.
#
# Destroying this stack schedules the seal key for deletion. Every snapshot in
# the bucket -- and the GCS mirror of it -- becomes ciphertext the moment that
# completes, and nothing in the platform can bring OpenBao back. So the gate
# is a separate, deliberately ugly variable rather than the usual confirm
# prompt, and the message says what is about to be lost.
#
# The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`;
# the literal must reach bash.
script "destroy" {
  name        = "OpenBao lineage destroy (guarded)"
  description = "Destroy the seal key, snapshot bucket and drill role. Requires TM_LINEAGE_DESTROY=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_LINEAGE_DESTROY:-}" != "true" ]; then
          echo "[skip] opentofu/aws/openbao/lineage destroy: this stack holds the OpenBao seal"
          echo "       key and the snapshot bucket. Destroying it makes every snapshot,"
          echo "       including the GCS mirror, permanently unreadable. Set"
          echo "       TM_LINEAGE_DESTROY=true only if that is genuinely what you want."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
        ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}
```

- [ ] **Step 9: `.trivyignore.yaml`**

```yaml
misconfigurations:
  # S3 access logging. The bucket holds ~1 KB objects written by a CronJob and
  # read by a deploy; OpenBao's own audit is where secret-access auditing
  # belongs, not S3 request logs about a backup file.
  - id: AVD-AWS-0089
    statement: "No access logging on the snapshot bucket: request logs on a backup artefact add cost and no signal."
```

- [ ] **Step 10: Remove the Crossplane manifests**

```bash
git rm security/aws-0/openbao-snapshot/kms.yaml security/aws-0/openbao-snapshot/s3-bucket.yaml
```

Replace `security/aws-0/openbao-snapshot/kustomization.yaml` with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: security

# The bucket and its KMS key used to be Crossplane MRs here. They are now
# OpenTofu resources in opentofu/aws/openbao/lineage: rehydrate reads the bucket
# BEFORE this cluster exists, so the cluster cannot be what creates it. The MRs
# carried no `Delete` management policy, so removing them orphaned the AWS
# objects rather than deleting them, and the lineage stack imported them.
resources:
  - ../../base/openbao-snapshot
```

- [ ] **Step 11: Validate**

```bash
tofu fmt -recursive opentofu/aws/openbao/lineage
(cd opentofu/aws/openbao/lineage && tofu init -backend=false >/dev/null && tofu validate)
(cd opentofu/aws/openbao/lineage && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .)
./scripts/validate-manifests.sh
```

Expected: `Success! The configuration is valid.`, trivy exit 0, manifests `Invalid: 0, Skipped: 0`.

- [ ] **Step 12: Commit**

```bash
git add opentofu/aws/openbao/lineage security/aws-0/openbao-snapshot
git commit -m "feat(openbao): AWS lineage stack -- multi-region seal key, snapshot bucket, drill role

The seal key leaves the ephemeral cluster stack (10-day deletion window,
new key every rebuild) for a persistent stack with a replica in eu-west-1.
The snapshot bucket and its key move from Crossplane to the same stack so
they exist before the cluster that reads them. A GitHub OIDC role lets the
weekly drill restore a snapshot with no recovery keys. destroy is gated
on TM_LINEAGE_DESTROY=true."
```

---

### Task 4: AWS cluster stack — seal from lineage, Raft in `dev`, fixed NLB IPs, pre-destroy snapshot

**Files:**
- Delete: `opentofu/aws/openbao/cluster/kms.tf`
- Create: `opentofu/aws/openbao/cluster/lineage.tf`
- Modify: `opentofu/aws/openbao/cluster/iam.tf:73-92`
- Modify: `opentofu/aws/openbao/cluster/data.tf:88` (`kms_unseal_key_id`)
- Modify: `opentofu/aws/openbao/cluster/scripts/startup_script.sh:118-136`
- Modify: `opentofu/aws/openbao/cluster/load_balancer.tf:1-5`
- Modify: `opentofu/aws/openbao/cluster/outputs.tf`
- Modify: `opentofu/aws/openbao/cluster/stack.tm.hcl`
- Modify: `opentofu/aws/openbao/cluster/autoscaling_group.tf:155-176` (comment only)
- Modify: `opentofu/aws/openbao/cluster/variables.tf:44-48` (comment only)
- Create: `opentofu/aws/openbao/cluster/workflows.tm.hcl`
- Modify: `opentofu/aws/openbao/cluster/README.md` (table)

- [ ] **Step 1: Read the seal key from the lineage**

```bash
git rm opentofu/aws/openbao/cluster/kms.tf
```

Create `opentofu/aws/openbao/cluster/lineage.tf`:

```hcl
# The seal key is lineage state, not cluster state. It used to be created here
# (kms.tf) and destroyed with the stack, which made every snapshot from the
# previous lineage unreadable by the next cluster. opentofu/aws/openbao/lineage
# owns it now; this stack only looks it up.
#
# A data source rather than a remote-state read, deliberately: this stack then
# needs no read access to the lineage stack's state, and survives that state
# moving. The cost is that `tofu plan` here FAILS until the lineage stack has
# been applied, with a not-found error naming the alias but not the stack that
# owns it -- the `after` edge in stack.tm.hcl only orders a full
# `terramate script run`. If you are running tofu directly and see that error,
# apply opentofu/aws/openbao/lineage first.
data "aws_kms_alias" "seal" {
  name = var.seal_key_alias
}
```

And add to `variables.tf` — a literal here and a `var.seal_key_alias` in the
lineage stack, with nothing coupling them, is how the two drift apart:

```hcl
variable "seal_key_alias" {
  description = "Alias of the seal key this node unseals with. MUST match `seal_key_alias` in opentofu/aws/openbao/lineage, which creates it -- nothing enforces that, and a mismatch surfaces as a plan-time 'alias not found'."
  type        = string
  default     = "alias/openbao-seal"
}
```

In `iam.tf`, replace the `resources = [aws_kms_key.openbao.arn]` line inside `data "aws_iam_policy_document" "openbao-kms-unseal"` with:

```hcl
    resources = [data.aws_kms_alias.seal.target_key_arn]
```

In `data.tf`, replace `"kms_unseal_key_id"     = aws_kms_key.openbao.id` with:

```hcl
      "kms_unseal_key_id"     = data.aws_kms_alias.seal.target_key_id
```

- [ ] **Step 2: Raft in every mode**

In `scripts/startup_script.sh`, replace:

```bash
%{ if dev_mode }
storage "file" {
  path = "${openbao_data_path}"
}
%{ else }
storage "raft" {
  path = "${openbao_data_path}"
  node_id = "$INSTANCE_ID"
  retry_join {
    auto_join               = "provider=aws region=${region} tag_key=OpenBaoInstance tag_value=${openbao_instance}"
    auto_join_scheme        = "https"
    auto_join_port          = 8200
    leader_tls_servername   = "${leader_tls_servername}"
    leader_client_cert_file = "/opt/openbao/tls/tls.crt"
    leader_client_key_file  = "/opt/openbao/tls/tls.key"
    leader_ca_cert_file     = "/opt/openbao/tls/ca.pem"
  }
}
%{ endif }
```

with:

```bash
# Raft in BOTH modes. `dev` used to run the `file` backend, which can neither
# take nor receive a snapshot -- so a dev node's contents died with it. A
# single-node raft cluster costs nothing extra: `operator init` bootstraps it,
# and retry_join finds only itself. In `ha` the same stanza joins five nodes.
storage "raft" {
  path = "${openbao_data_path}"
  node_id = "$INSTANCE_ID"
  retry_join {
    auto_join               = "provider=aws region=${region} tag_key=OpenBaoInstance tag_value=${openbao_instance}"
    auto_join_scheme        = "https"
    auto_join_port          = 8200
    leader_tls_servername   = "${leader_tls_servername}"
    leader_client_cert_file = "/opt/openbao/tls/tls.crt"
    leader_client_key_file  = "/opt/openbao/tls/tls.key"
    leader_ca_cert_file     = "/opt/openbao/tls/ca.pem"
  }
}
```

The `dev_mode` template variable stays (nothing else reads it, and removing it from `data.tf` is churn with no effect; leave it).

In `autoscaling_group.tf`, replace the comment paragraph starting `# NOT in dev, and the reason matters:` through `# the running one stays a deliberate manual act.` with:

```hcl
  # NOT in dev. dev is a single node whose raft store lives on the root
  # volume, which block_device_mappings marks delete_on_termination. A refresh
  # would terminate the only live copy; the lineage's newest snapshot brings it
  # back on the next deploy, but everything written since that snapshot is
  # lost. The triggers are routine (an AMI publish, an openbao_version bump), so
  # replacing the running dev node stays a deliberate act: take a snapshot
  # first (`openbao-config.sh pre-destroy-snapshot`), then recycle.
```

In `variables.tf`, replace the `root_volume_size` description with:

```hcl
  description = "Size (GiB) of the encrypted gp3 root volume. In dev mode this also holds the single-node raft store, so it needs headroom beyond the AMI default of 8."
```

- [ ] **Step 3: Fixed private IPs on the NLB**

In `load_balancer.tf`, replace:

```hcl
resource "aws_lb" "this" {
  name               = local.name
  internal           = true
  load_balancer_type = "network"
  subnets            = data.aws_subnets.private.ids
```

with:

```hcl
# One private subnet per AZ, resolved individually so each can carry a fixed
# address below.
data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

resource "aws_lb" "this" {
  name               = local.name
  internal           = true
  load_balancer_type = "network"

  # Fixed IPs are only useful if every one of them works, and by default they
  # would not. NLB cross-zone load balancing is DISABLED unless asked for: an
  # NLB node then serves only targets registered in its own AZ and DROPS
  # traffic when it has none. subnet_mapping below enables three AZs, but
  # `dev` runs one instance, in whichever AZ the ASG picked -- so two of the
  # three addresses would blackhole, and which one worked would change on
  # every instance replacement. That is exactly the instability these fixed
  # addresses exist to remove.
  #
  # It is invisible on the DNS path, which is why this is easy to miss:
  # AWS drops target-less AZs from the NLB's own DNS answer, and the Route53
  # alias evaluates target health. The fixed-IP path has no such fallback --
  # security/base/openbao-endpoint/remote pins ONE literal address.
  #
  # Cost is cross-zone data processing, which at OpenBao API volume is noise.
  enable_cross_zone_load_balancing = true

  # Fixed private IPs, not AWS-assigned. A remote cluster reaches this OpenBao
  # through a Tailscale egress Service annotated with one of these addresses
  # (security/base/openbao-endpoint/remote), and that annotation must survive
  # a rebuild of this stack. cidrhost(-6) is the sixth address from the top of
  # each /20: AWS reserves the first four and the last one, and EKS assigns
  # from the pool at random, so a high fixed address is the least likely to
  # collide.
  #
  # If creation fails with "address already in use", the usual cause is the
  # PREVIOUS load balancer's ENI not yet released after a destroy -- wait and
  # re-apply, the address comes back. Change the offset only if a long-lived
  # ENI genuinely holds it, and treat that as a contract change: the remote
  # cluster's openbao_target_ip has to move with it.
  dynamic "subnet_mapping" {
    for_each = data.aws_subnet.private
    content {
      subnet_id            = subnet_mapping.value.id
      private_ipv4_address = cidrhost(subnet_mapping.value.cidr_block, -6)
    }
  }
```

**This replaces the load balancer**, and the replacement is the riskiest apply in
Stage 1 — say so in the comment block above `aws_lb` as well. Changing `subnets`
to `subnet_mapping` forces a new NLB, and OpenTofu's default order is
destroy-then-create: listener down, NLB down, NLB up, listener up, then the
Route53 alias updates. That is a **multi-minute OpenBao API outage** plus stale
DNS for the alias record's cache lifetime, during which cert-manager cannot
issue, the snapshot CronJob fails, and `OpenBaoDown` fires. Do not run it during
a certificate renewal, and **take a snapshot first** — except on the very first
such apply, where you cannot, because the node is still on the `file` backend
until it reboots onto Raft.

Do **not** add `create_before_destroy` to fix the outage: a target group cannot
be associated with two load balancers, so it would deadlock the apply. The
target group and listener re-attach correctly as written — the TG is not
force-replaced and the ASG references it by an unchanged ARN.

Append to `outputs.tf`:

```hcl
# A MAP keyed by availability zone, not a list.
#
# `aws_lb.subnet_mapping` is a set in the provider schema, so a list built from
# it comes out in hash order -- not AZ order, and not stable when an AZ is added
# or removed. The one consumer of this output picks a SINGLE address
# (openbao_target_ip, in opentofu/gcp/gke/configure), so it needs to know which
# address belongs to which zone rather than being handed three in arbitrary
# order. Computed from the subnet data source with the same expression the
# resource uses, so it is also known at plan time instead of only after apply.
output "nlb_private_ips" {
  description = "Fixed private address of the internal NLB, per availability zone. A remote cluster's openbao_target_ip is one of these (opentofu/gcp/gke/configure)."
  value       = { for s in data.aws_subnet.private : s.availability_zone => cidrhost(s.cidr_block, -6) }
}
```

- [ ] **Step 4: Order after the lineage**

In `stack.tm.hcl`, replace:

```hcl
  after = [
    "/opentofu/aws/network"
  ]
```

with:

```hcl
  after = [
    "/opentofu/aws/network",
    "/opentofu/aws/openbao/lineage",
  ]
```

- [ ] **Step 5: Pre-destroy snapshot**

Create `opentofu/aws/openbao/cluster/workflows.tm.hcl`:

```hcl
# Only `destroy` is overridden; deploy / preview / drift inherit the global
# scripts.
#
# The node's raft store is delete_on_termination. Before it goes, take one last
# snapshot into the lineage bucket so the next deploy's rehydrate brings back
# everything written since the CronJob's last run. This has to happen HERE, in
# the operator's context: `--reverse destroy` has already removed the EKS
# cluster (and the CronJob in it) by the time this stack's turn comes.
#
# The management stack's gated destroy runs before this one and does nothing,
# which is what keeps the PKI mount and policies inside this final snapshot.
script "destroy" {
  name        = "OpenBao cluster destroy (snapshot first)"
  description = "Snapshot to the lineage bucket, then destroy the cluster stack"

  job {
    name        = "destroy"
    description = "Confirm, snapshot, destroy"
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # The CA fetch and the snapshot share ONE gate, in one bash step.
      #
      # They were two separate ungated steps, and that made
      # TM_OPENBAO_SKIP_SNAPSHOT useless for the case it exists for. The CA
      # fetch exits non-zero when the ca-chain secret is missing or unreadable,
      # and `openbao-config.sh`'s own --ca-file readability check runs during
      # argument parsing, before dispatch reaches the skip check inside
      # pre_destroy_snapshot. So a destroy of a node that is "already gone" --
      # exactly when its surrounding secrets are most likely gone too -- was
      # hard-blocked by an error about a CA chain, with the documented override
      # having no effect. The operator's only recourse was editing this file.
      #
      # The CA exists only to let the snapshot verify TLS, so if the snapshot is
      # skipped the CA is not wanted either. One gate, checked before either.
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        if [ "$${TM_OPENBAO_SKIP_SNAPSHOT:-false}" = "true" ]; then
          echo "[skip] TM_OPENBAO_SKIP_SNAPSHOT=true -- no CA fetch, no pre-destroy snapshot."
          echo "       Everything written since the last scheduled snapshot will be lost."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --root-ca-secret-name "${global.ca_chain_secret_name}" \
          --ca-output-file .tls/ca.pem \
          --region "${global.region}" --profile "${global.profile}"
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" pre-destroy-snapshot \
          --url "${global.openbao_url}" \
          --root-token-secret-name "${global.root_token_secret_name}" \
          --snapshot-bucket "${global.snapshot_bucket_name}" \
          --ca-file .tls/ca.pem \
          --region "${global.region}" --profile "${global.profile}"
      BASH
      ],
      [global.provisioner, "init", "-lock-timeout=5m"],
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}
```

`global.ca_chain_secret_name` and `global.snapshot_bucket_name` are added to `opentofu/config.tm.hcl` in Task 5. Terramate evaluates globals lazily, so this file parses before Task 5 lands but `terramate script run` would fail until it does — Tasks 4 and 5 ship in consecutive commits on the same branch.

- [ ] **Step 6: README table**

In `opentofu/aws/openbao/cluster/README.md`, replace the row `| OpenBao storage type | file         | raft                  |` with `| OpenBao storage type | raft (single node) | raft                  |`, and replace the row `| Disk type            | gp3 (root)   | NVMe instance store   |` with `| Disk type            | gp3 (root)   | NVMe instance store   |` unchanged. Add after the table:

```markdown
Both modes are Raft since the lineage design (2026-09): a `file` backend cannot take
or receive a snapshot, and the node is rebuilt from the lineage's newest snapshot on
every deploy — see [OpenBao](https://cnref.ogenki.io/docs/platform/security/openbao/).
```

- [ ] **Step 7: Validate**

```bash
tofu fmt -recursive opentofu/aws/openbao/cluster
(cd opentofu/aws/openbao/cluster && tofu init -backend=false >/dev/null && tofu validate)
(cd opentofu/aws/openbao/cluster && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .)
shellcheck -e SC1083,SC2086 opentofu/aws/openbao/cluster/scripts/startup_script.sh || true
```

Expected: `Success! The configuration is valid.`, trivy exit 0. (The startup script is a template; shellcheck noise on `${...}` template syntax is expected, hence `|| true` — read its output for anything that is not a template-variable complaint.)

- [ ] **Step 8: Commit**

```bash
git add opentofu/aws/openbao/cluster
git commit -m "feat(openbao): cluster reads its seal from the lineage, runs raft in dev, snapshots before destroy

The seal key comes from alias/openbao-seal instead of a per-deploy key.
dev mode moves from file to single-node raft so it can take and receive
snapshots. The internal NLB gets fixed private IPs a remote cluster can
target across rebuilds. destroy takes a last snapshot into the lineage
bucket first."
```

---

### Task 5: Terramate globals and the AWS management stack — rehydrate, destroy gate, `lineage/` mount, PKI from the pre-signed intermediate, AppRole removed

**Files:**
- Modify: `opentofu/config.tm.hcl:44-52`
- Modify: `opentofu/aws/openbao/management/workflows.tm.hcl`
- Modify: `opentofu/aws/openbao/management/pki.tf`
- Modify: `opentofu/aws/openbao/management/mounts.tf`
- Modify: `opentofu/aws/openbao/management/auth.tf`
- Modify: `opentofu/aws/openbao/management/secrets.tf`
- Modify: `opentofu/aws/openbao/management/outputs.tf`
- Modify: `opentofu/aws/openbao/management/variables.tf`
- Modify: `opentofu/aws/openbao/management/variables.tfvars`
- Modify: `opentofu/aws/openbao/management/policies/snapshot.hcl`
- Modify: `opentofu/aws/openbao/management/providers.tf`, `roles.tf`,
  `scripts/openbao-config.sh` and `scripts/secret-store.sh` — **comments and one
  stale list**, all falsified by Steps 3 and 6 and none of them obvious from the
  diff. `providers.tf` says this stack "imports the CA, signs the intermediate,
  and writes every policy and AppRole on the platform" (it no longer signs the
  intermediate and writes no platform AppRole); `roles.tf` and `variables.tf` both
  say `pki_max_lease_ttl` bounds "the mount and the intermediate", but the
  intermediate's lifetime now comes from the offline ceremony; `openbao-config.sh`'s
  `write_ca` comment still documents the AWS branch reading the deleted `root-ca`
  secret as JSON with `.ca` and `.bundle`; and `secret-store.sh`'s `OLD_NAMES` still
  lists the removed cert-manager AppRole entry, so `migrate-aws` would either copy a
  dead credential or report it absent.
- Modify: `opentofu/aws/openbao/management/auth.tf` — **one comment, and it hides
  something.** Step 6 says to leave the `userpass` and `app` blocks exactly as they
  are, which is right about the code and wrong about the comment above them: it
  reads "Deliberately no `token_bound_cidrs`, unlike the machine roles above", and
  after Step 6 there are no machine roles above. Worse, the JWT roles that replaced
  them carry no CIDR bind either, so the sentence conceals a real narrowing that
  went away. Say that machine auth is now bound by ServiceAccount subject and
  audience instead of by CIDR.
- Modify: `opentofu/aws/openbao/management/autopilot.tf:1-9` (comment only)

- [ ] **Step 1: Globals**

In `opentofu/config.tm.hcl`, replace:

```hcl
  root_ca_secret_name              = "certificates/priv.aws.ogenki.io/root-ca" # pragma: allowlist secret
  cert_manager_approle_secret_name = "openbao/cloud-native-ref/approles/cert-manager" # pragma: allowlist secret
  cert_manager_approle             = "cert-manager"
```

**Match on the three variable names, not character-for-character.** The two
`# pragma: allowlist secret` comments above are on this *quotation* only — they
stop `detect-secrets` flagging this plan file — and are **not** in
`config.tm.hcl`, where only `recovery_keys_secret_name` carries one. The lines to
replace are the three named here, whatever trailing comments they do or do not
have.

with:

```hcl
  # PKI material, both written by the offline signing ceremony (PKI & Secrets
  # page). The intermediate's private key is in `intermediate-ca` and nowhere
  # else on AWS; `ca-chain` is certificates only ({"ca": "<intermediate>\n<root>"})
  # and is what every client verifies against. The former `root-ca` entry, which
  # held the ROOT private key, is gone -- the root is offline, as on GCP.
  intermediate_ca_secret_name = "certificates/priv.aws.ogenki.io/intermediate-ca" # pragma: allowlist secret
  ca_chain_secret_name        = "certificates/priv.aws.ogenki.io/ca-chain"        # pragma: allowlist secret

  # The lineage's snapshot bucket (opentofu/aws/openbao/lineage). Read by the
  # management stack's rehydrate step and the cluster stack's pre-destroy
  # snapshot, both of which run BEFORE the cluster that used to own the bucket.
  snapshot_bucket_name = "eu-west-3-ogenki-openbao-snapshot"
```

Then find every remaining reference and fix it:

Run: `grep -rn "root_ca_secret_name\|cert_manager_approle" opentofu/ --include='*.hcl' --include='*.tf' --include='*.tfvars'`
Expected hits, all handled in this task or Task 6: `opentofu/aws/openbao/management/workflows.tm.hcl` (3, use `global.ca_chain_secret_name`), `opentofu/aws/openbao/management/{variables.tf,variables.tfvars,secrets.tf,outputs.tf,pki.tf}`, `opentofu/aws/eks/configure/{variables.tf,variables.tfvars,data.tf,kubernetes.tf}` (Task 6).

- [ ] **Step 2: Management workflow — CA first, then rehydrate, and a gated destroy**

In `opentofu/aws/openbao/management/workflows.tm.hcl`:

In the `globals "openbao_ca_cmd"` block replace `global.root_ca_secret_name,` with `global.ca_chain_secret_name,`.

Replace the whole `script "destroy"` block with:

```hcl
# Gated like the lineage stack, and for the same reason: everything this stack
# manages -- the PKI mount, auth mounts, policies, the `app` namespace, the
# lineage/ marker mount -- is lineage state that the snapshot carries. Destroying
# it at teardown would delete those from the live OpenBao moments before the
# cluster stack's pre-destroy snapshot, so the snapshot would bring back an
# empty store. The stack's OpenTofu state stays valid across rebuilds because a
# rehydrated OpenBao holds the same resources at the same paths.
script "destroy" {
  description = "Guarded: this stack's resources are lineage state. Requires TM_LINEAGE_DESTROY=true"
  job {
    name        = "destroy"
    description = "Opentofu destroy, only when TM_LINEAGE_DESTROY=true"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_LINEAGE_DESTROY:-}" != "true" ]; then
          echo "[skip] opentofu/aws/openbao/management destroy: the PKI mount, auth mounts and"
          echo "       policies here are lineage state carried by the raft snapshot. Deleting them"
          echo "       now would empty the snapshot the cluster stack takes next. Set"
          echo "       TM_LINEAGE_DESTROY=true to destroy the lineage on purpose."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh" --tm-run bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
        bash "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh" --tm-run \
          bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --root-ca-secret-name "${global.ca_chain_secret_name}" --ca-output-file .tls/ca.pem \
          --region "${global.region}" --profile "${global.profile}"
        # Same #3411 race on the way down -- see the apply job.
        ${global.provisioner} destroy -auto-approve -parallelism=1 -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}
```

In `script "deploy"`, replace the first command (the `init` invocation, from `[` through `"--skip-verify",` `],`) **and** the second command (the `ca` invocation) with these two, in this order — CA first so rehydrate verifies TLS:

```hcl
      # 1. Materialise the CA chain. Has to be a script step rather than a
      #    local_file resource: provider configuration is evaluated before any
      #    resource exists, so the file must already be on disk at `tofu init`.
      #    It also runs before rehydrate so the restore verifies the server.
      global.openbao_ca_cmd.args,
      # 2. Rehydrate -- or, on the first deploy of a lineage, initialise.
      #
      #    A fresh node reports uninitialised. If the lineage bucket holds a
      #    snapshot, this initialises with throwaway shares it never stores and
      #    restores the newest one; the root token and recovery keys already in
      #    Secrets Manager belong to the restored state. If the bucket is empty,
      #    it is a plain init and the new keys are stored -- same as before.
      #    Idempotent: an initialised, unsealed node is left alone.
      [
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
        "--tm-run",
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh",
        "rehydrate",
        "--url",
        global.openbao_url,
        "--root-token-secret-name",
        global.root_token_secret_name,
        "--recovery-keys-secret-name",
        global.recovery_keys_secret_name,
        "--snapshot-bucket",
        global.snapshot_bucket_name,
        "--ca-file",
        ".tls/ca.pem",
        "--region",
        global.region,
        "--profile",
        global.profile,
      ],
```

Delete the old comment block above the removed `init` command (`# Initialize OpenBao cluster. Stores the root token ...` through `# request carries no secret in either direction.`).

- [ ] **Step 3: PKI from the pre-signed intermediate**

Replace the whole of `opentofu/aws/openbao/management/pki.tf` with:

```hcl
resource "vault_mount" "pki" {
  path        = var.pki_mount_path
  type        = "pki"
  description = var.pki_common_name

  default_lease_ttl_seconds = var.pki_max_lease_ttl
  max_lease_ttl_seconds     = var.pki_max_lease_ttl
}

# The openssl-made intermediate IS the issuer -- the shape GCP has had since
# 2026-08-24, adopted here.
#
# This stack used to import a bundle containing the ROOT key and have OpenBao
# generate and sign its own intermediate inside the mount (four resources:
# key, CSR, root_sign_intermediate, set_signed). That put the root private key
# on a networked system, which the PKI & Secrets page carried as an accepted
# trade-off for a reference platform. It is no longer traded: the root signed
# this intermediate offline, once, and the `root-ca` secret that held its key
# has been deleted from Secrets Manager. Tailnet clients now trust ONE root for
# both clouds.
resource "vault_pki_secret_backend_config_ca" "pki" {
  backend    = vault_mount.pki.path
  pem_bundle = jsondecode(data.aws_secretsmanager_secret_version.intermediate_ca.secret_string)["bundle"]
}
```

- [ ] **Step 4: The `lineage/` marker mount**

Append to `opentofu/aws/openbao/management/mounts.tf`:

```hcl

# Root-namespace kv-v2 mount for lineage bookkeeping. Today it holds one key,
# `check_timestamp`, written by the snapshot job before every snapshot and read
# by a restore to report the age of what it just installed. It lives in root,
# not in the `app` tenant namespace where the marker used to be, because it is
# a platform fact and because GCP has no `app` namespace.
resource "vault_mount" "lineage" {
  path        = "lineage"
  type        = "kv-v2"
  description = "Lineage bookkeeping: the snapshot freshness marker"
}
```

- [ ] **Step 5: Snapshot policy grants the marker**

Replace `opentofu/aws/openbao/management/policies/snapshot.hcl` with:

```hcl
# Least privilege for the snapshot agent: read the raft snapshot endpoint, and
# write the one key that records when the snapshot was taken.
#
# `sys/storage/raft/configuration` used to be granted here so the job could find
# the raft leader and connect straight to its private IP. That path is gone —
# the job now goes through the NLB and relies on standby nodes forwarding the
# request to the active node — so the grant went with it.
#
# Note this policy must live in the ROOT namespace: sys/storage/raft/* is a
# restricted endpoint, callable only from root.
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# The freshness marker (mounts.tf, `lineage/`). kv-v2 puts data under /data/.
path "lineage/data/check_timestamp" {
  capabilities = ["create", "update", "read"]
}
```

- [ ] **Step 6: Remove the AppRole backend and its roles**

In `opentofu/aws/openbao/management/auth.tf`, delete everything from the header comment `# Platform auth, root namespace` down to and including the `vault_approle_auth_backend_role.cert_manager` resource (the `approle` backend, `snapshot` role and `cert_manager` role). Insert in its place:

```hcl
# Platform auth, root namespace
# -----------------------------
# Machine authentication for the two clusters is the JWT method, one mount per
# cluster (`jwt/aws-0`, `jwt/gcp-0`), created by that cluster's `configure`
# stack -- opentofu/aws/eks/configure/openbao.tf and its GKE twin. It lives
# there rather than here because the mount's `oidc_discovery_url` is the EKS
# issuer, which carries a per-cluster ID that changes on every rebuild, and
# this stack runs BEFORE eks/init. The policies those roles reference stay
# here (policies.tf), so the authorisation model has one owner.
#
# The AppRole backend that used to be here (roles `snapshot-agent` and
# `cert-manager`, credentials published to Secrets Manager) is gone: a JWT
# login mints no long-lived credential, so there is nothing to store, rotate
# or leak.
#
# Resources below take no `namespace` argument — that is how the provider
# addresses the root namespace.
```

Keep the `userpass` backend, `admin_user`, and the `app` namespace AppRole exactly as they are.

- [ ] **Step 7: Secrets — drop the AppRole entries, keep the admin password**

In `opentofu/aws/openbao/management/secrets.tf`:

Replace:

```hcl
# Get the root CA bundle from AWS Secrets Manager
data "aws_secretsmanager_secret" "root_ca" {
  name = var.root_ca_secret_name
}

data "aws_secretsmanager_secret_version" "root_ca" {
  secret_id = data.aws_secretsmanager_secret.root_ca.id
}
```

with:

```hcl
# The openssl-made intermediate: certificate AND private key, as one pem_bundle
# under the `bundle` key. Written by the offline ceremony, never by this stack.
# The ROOT key is deliberately absent from AWS entirely.
data "aws_secretsmanager_secret_version" "intermediate_ca" {
  secret_id = var.intermediate_ca_secret_name
}
```

Delete the block from `# Store AppRole credentials in AWS Secrets Manager` through the `aws_secretsmanager_secret_version.cert_manager_approle_credentials` resource. Delete the block from `# Snapshot agent AppRole` to the end of the file (the `locals` block with `openbao_address`/`snapshot_bucket_name`, and the three `snapshot_approle_credentials` resources) — **but keep `local.openbao_address`**, which `providers.tf` uses. Re-add it as:

```hcl
locals {
  openbao_address = var.openbao_domain_name == "" ? format("https://bao.%s:8200", var.domain_name) : var.openbao_domain_name
}
```

- [ ] **Step 8: Outputs, variables, tfvars**

In `outputs.tf`, delete the `cert_manager_approle_credentials_secret_arn` and `cert_manager_approle_role_id` outputs.

In `variables.tf`: delete `root_ca_secret_name`, `cert_manager_approle_secret_name`,
`snapshot_approle_secret_name`, `recovery_keys_secret_name`, `snapshot_bucket_name`
— **and `pki_key_type` and `pki_key_bits`.** Those last two are not obvious from
the diff: their only consumer was `vault_pki_secret_backend_key.this`, which
Step 3 deletes, and pre-commit's `terraform_tflint` hook fails on
`terraform_unused_declarations` until they go. Also fix two descriptions that
Step 3 falsified: `openbao_ca_cert_file` still says the chain comes "from the
root CA secret in AWS Secrets Manager" (it is the ca-chain secret now), and in
`secrets.tf` the "Human operator password" block still lists "both AppRole
secret IDs" among the credentials this stack manages — Step 6 removed them. Add:

```hcl
variable "intermediate_ca_secret_name" {
  description = "AWS Secrets Manager entry holding the intermediate CA pem_bundle ({\"bundle\": \"<cert>\\n<key>\"}) from the offline ceremony. Its private key exists nowhere else on AWS."
  type        = string
}
```

Replace the `mode` variable's comment (the paragraph starting `# Getting it wrong is loud rather than silent`) with:

```hcl
# Both modes are raft now; `mode` only decides whether autopilot's dead-server
# cleanup is configured (autopilot.tf), which needs the five-node quorum.
```

and its description with `"Storage mode of the target OpenBao cluster: 'dev' (single-node raft) or 'ha' (five-node raft). Must match the cluster stack."`.

In `variables.tfvars`, replace the `root_ca_secret_name` line with an `intermediate_ca_secret_name` line whose value is the intermediate entry's name from the fixed-values table, delete the `cert_manager_approle_secret_name` line, and replace the `pki_domains` list with:

```hcl
# Both private domains: the active OpenBao issues for both clusters (design,
# "PKI"), so a gcp-0 Certificate signed here must be allowed. cluster.local
# covers in-cluster Service names.
pki_domains = [
  "cluster.local",
  "priv.aws.ogenki.io",
  "priv.gcp.ogenki.io"
]
```

`autopilot.tf` needs no change: `count = var.mode == "ha" ? 1 : 0` is still right, since dead-server cleanup only makes sense with a quorum. In `observability/base/victoria-metrics-k8s-stack/vmrules/openbao.yaml`, replace the comment line `# Neither fires in dev mode: file storage has no raft and no autopilot,` with `# Neither fires in dev mode: a single raft node runs no autopilot,` (the next line, `so the metric does not exist.`, stays).

- [ ] **Step 9: Validate**

```bash
tofu fmt -recursive opentofu/aws/openbao/management
(cd opentofu/aws/openbao/management && tofu init -backend=false >/dev/null && tofu validate)
(cd opentofu/aws/openbao/management && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .)
grep -rn "approle" opentofu/aws/openbao/management/*.tf
terramate fmt --check opentofu/config.tm.hcl opentofu/aws/openbao/management/workflows.tm.hcl; echo "tm_fmt=$?"
```

Expected: valid; trivy exit 0; `tm_fmt=0`.

The `approle` grep is a **read-and-judge, not a pass/fail**: every remaining hit
must belong to the `app` tenant namespace's own AppRole, which this task keeps as
the worked tenancy example. Expect roughly four lines — the `vault_auth_backend`
`approle_app`, the `vault_approle_auth_backend_role` `app`, and their
`type = "approle"` / `backend = ...` attributes. What must be **gone** is a
root-namespace `approle` backend and the `snapshot`/`cert_manager` roles on it.
(An earlier revision of this step piped through `grep -v` and asserted an empty
result; the filter could not span a whole resource block, so it reported hits
that were entirely legitimate.)

`terramate fmt` is the right formatter for `.tm.hcl` — `tofu fmt` does not touch
those files, so a Step 1 edit to `config.tm.hcl` can leave real alignment drift
that nothing else catches.

- [ ] **Step 10: Commit**

```bash
# Explicit pathspec, and note the last two: Step 8 edits a VMRule outside this
# stack, and the detect-secrets hook rewrites .secrets.baseline when a secret
# NAME disappears from the tracked files. Neither is under
# opentofu/aws/openbao/management, so a narrower `git add` silently drops them.
git add opentofu/config.tm.hcl opentofu/aws/openbao/management scripts/openbao-config.sh \
  scripts/secret-store.sh observability/base/victoria-metrics-k8s-stack/vmrules/openbao.yaml \
  .secrets.baseline
git commit -m "feat(openbao): management stack rehydrates from the lineage, imports a pre-signed intermediate, drops AppRole

Deploy now fetches the CA chain first, then rehydrates the node from the
newest snapshot (plain init on a lineage's first deploy). destroy is gated
on TM_LINEAGE_DESTROY because these resources are lineage state. The PKI
mount imports the intermediate the offline root signed, the shape GCP
already had, so the root key leaves AWS. The AppRole backend, its two
roles and their Secrets Manager entries go; cluster auth is the JWT method
owned by each cluster's configure stack."
```

---

### Task 6: `eks/configure` — vault provider, `jwt/aws-0` mount and roles, ConfigMap variables

**Files:**
- Create: `opentofu/aws/eks/configure/openbao.tf`
- Modify: `opentofu/aws/eks/configure/providers.tf`
- Modify: `opentofu/aws/eks/configure/versions.tf`
- Modify: `opentofu/aws/eks/configure/data.tf:35-41`
- Modify: `opentofu/aws/eks/configure/variables.tf:113-118`
- Modify: `opentofu/aws/eks/configure/variables.tfvars:14`
- Modify: `opentofu/aws/eks/configure/kubernetes.tf:84-118`
- Modify: `opentofu/aws/eks/configure/workflows.tm.hcl` (`deploy` and `preview`)
- Modify: `opentofu/aws/eks/init/workflows.tm.hcl` (the `stage2-cilium-and-flux` job, which runs this stack's apply)

- [ ] **Step 1: Provider and version**

Append to `providers.tf`:

```hcl

# OpenBao, for the JWT auth mount this cluster authenticates through
# (openbao.tf). Configured like the management stack: the lineage root token
# from Secrets Manager, and the CA chain the deploy workflow writes to .tls/
# before `tofu init` -- a provider block cannot depend on a resource.
provider "vault" {
  address      = "https://bao.${var.private_domain_name}:8200"
  token        = jsondecode(data.aws_secretsmanager_secret_version.openbao_root_token.secret_string)["token"]
  ca_cert_file = var.openbao_ca_cert_file
}
```

In `versions.tf`, add inside `required_providers`:

```hcl
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
```

- [ ] **Step 2: Data sources and variables**

In `data.tf`, replace:

```hcl
data "aws_secretsmanager_secret_version" "cert_manager_approle" {
  secret_id = var.cert_manager_approle_secret_name
}
```

with:

```hcl
# The lineage root token, for the vault provider. Read here rather than plumbed
# from the management stack's state: the two stacks share no other coupling.
data "aws_secretsmanager_secret_version" "openbao_root_token" {
  secret_id = var.openbao_root_token_secret_id
}
```

In `variables.tf`, replace the `cert_manager_approle_secret_name` variable with:

```hcl
variable "openbao_root_token_secret_id" {
  description = "Secrets Manager entry holding the OpenBao root token ({\"token\": ...}), used by the vault provider to create this cluster's JWT auth mount"
  type        = string
  default     = "openbao/cloud-native-ref/tokens/root"
  sensitive   = true
}

variable "openbao_ca_cert_file" {
  description = "CA chain used to verify OpenBao's server certificate. Written by `openbao-config.sh ca` in the deploy workflow; .tls/ is gitignored."
  type        = string
  default     = ".tls/ca.pem"
}

variable "openbao_jwt_audience" {
  description = "Audience every ServiceAccount token presented to OpenBao must carry. Consumers request it via serviceAccountRef.audiences / a projected token's audience."
  type        = string
  default     = "openbao"
}
```

In `variables.tfvars`, delete the `cert_manager_approle_secret_name` line (the one whose value is the AppRole entry named in the fixed-values table) and rewrite the comment block above it so it no longer refers to it. Concretely, the block becomes:

```hcl
# Cluster-internal bootstrap resources (gateway CRDs, flux-system namespace +
# secrets + vars ConfigMap, storage classes) are created in this stage, after
# the cluster exists — see kubernetes.tf. They previously lived in eks/init but
# that forced the kubectl provider to configure from not-yet-created cluster
# outputs (alekc/kubectl can't defer → "no configuration has been provided").
# github_app_secret_name defaults to github/flux-app
# openbao_root_token_secret_id defaults to openbao/cloud-native-ref/tokens/root
```

- [ ] **Step 3: The JWT mount and roles**

Create `openbao.tf`:

```hcl
# This cluster's way into OpenBao: the JWT auth method, validating projected
# ServiceAccount tokens against the cluster's public OIDC issuer.
#
# Why here and not in openbao/management: the EKS issuer URL carries a
# per-cluster ID that changes on every rebuild, and the management stack runs
# before eks/init. This stack already exists to bind a fresh cluster to the
# platform and runs after the issuer is known. The POLICIES the roles reference
# are the management stack's; only the mount and its roles live here.
#
# JWKS validation means OpenBao never talks to the API server -- it fetches the
# issuer's public keys over the internet -- which is what lets a REMOTE cluster
# authenticate to this OpenBao exactly the same way (opentofu/gcp/gke/configure).
# The cost: a ServiceAccount token revoked by Kubernetes stays valid until it
# expires, so role token TTLs are short.
resource "vault_jwt_auth_backend" "cluster" {
  path               = "jwt/${var.cluster_name}"
  type               = "jwt"
  description        = "Kubernetes ServiceAccount tokens from cluster ${var.cluster_name}"
  oidc_discovery_url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  bound_issuer       = data.aws_eks_cluster.this.identity[0].oidc[0].issuer

  # No mount `tune`. In hashicorp/vault v5 `tune` is a
  # `list(object({...}))` ATTRIBUTE, not a block, and its object type has eight
  # non-optional fields -- so `tune { ... }` is a syntax error and a partial
  # `tune = [{ default_lease_ttl = ... }]` fails on the fields it omits.
  # Verified against provider v5.11.0's schema on 2026-09-02. Every token this
  # mount issues comes from a role below, and those bound the TTL and the type
  # directly, so the mount-level tune bought nothing anyway.
}

locals {
  # role name => { sa, namespace, policies }. The policy names are created by
  # opentofu/aws/openbao/management/policies.tf. `external-secrets` has no
  # consumer until Stage 2 repoints the ClusterSecretStore; it is created now
  # so the auth contract is complete and smoke-testable.
  openbao_roles = {
    cert-manager = {
      service_account = "cert-manager"
      namespace       = "security"
      policies        = ["cert-manager"]
    }
    external-secrets = {
      service_account = "external-secrets"
      namespace       = "security"
      policies        = ["default"]
    }
    openbao-snapshot = {
      service_account = "openbao-snapshot"
      namespace       = "security"
      policies        = ["snapshot"]
    }
  }
}

resource "vault_jwt_auth_backend_role" "cluster" {
  for_each = local.openbao_roles

  backend   = vault_jwt_auth_backend.cluster.path
  role_name = each.key
  role_type = "jwt"

  # Exactly one ServiceAccount, by full subject, and exactly one audience.
  bound_audiences = [var.openbao_jwt_audience]
  bound_subject   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  user_claim      = "sub"

  token_policies = each.value.policies
  token_ttl      = 600
  token_max_ttl  = 1200
  # Service tokens, which is what a workload wants: revocable and leased.
  # Set per role rather than on the mount -- see the note above.
  token_type = "default-service"
}
```

- [ ] **Step 4: Remove the approle Secret, rewrite the two ConfigMap keys**

In `kubernetes.tf`, delete the whole `resource "kubectl_manifest" "flux_cert_manager_approle"` block (and the comment above it: `# Create secrets using kubectl_manifest instead of kubernetes_secret` … `to avoid plan-time validation issues with the kubernetes provider`). Keep `flux_system_secret`.

**Two dangling references go with it, in files this task's list does not name.**
`tofu validate` fails with "Reference to undeclared resource" until both are
removed, so they are part of this step:

- `opentofu/aws/eks/configure/locals.tf` — delete `local.cert_manager_approle`,
  which decoded the data source Step 2 removed.
- `opentofu/aws/eks/configure/main.tf` — remove
  `kubectl_manifest.flux_cert_manager_approle` from `helm_release.flux_instance`'s
  `depends_on` list.

Replace:

```hcl
      # Secret Manager keys for the two ExternalSecrets that need one:
      # security/base/openbao-snapshot/external-secrets.yaml and
      # apps/base/ai/llm/hf-token-externalsecret.yaml. Both are PATH-STYLE here
      # because AWS Secrets Manager permits "/"; gcp-0's ConfigMap carries flat
      # dash-separated IDs instead, because GCP Secret Manager forbids it. Same
      # keys, different shape per cloud -- ADR-0023.
      openbao_snapshot_secret = "security/openbao/openbao-snapshot" # pragma: allowlist secret
      llm_hf_token_secret     = "/platform/llm/hf_token"            # pragma: allowlist secret
```

with:

```hcl
      # The lineage's snapshot bucket, consumed by
      # security/base/openbao-snapshot/snapshot-cronjob.yaml as BUCKET_NAME.
      # Region-prefixed on AWS, project-prefixed on GCP (GCS names are global
      # and the Crossplane IAM condition keyed on the project prefix), so it is
      # a per-cluster variable rather than a literal in the shared manifest.
      openbao_snapshot_bucket = "${var.region}-ogenki-openbao-snapshot"
      # Secret Manager key for apps/base/ai/llm/hf-token-externalsecret.yaml.
      # PATH-STYLE here because AWS Secrets Manager permits "/"; gcp-0's
      # ConfigMap carries a flat dash-separated ID instead -- ADR-0023.
      llm_hf_token_secret = "/platform/llm/hf_token" # pragma: allowlist secret
```

- [ ] **Step 5: Deploy and preview fetch the CA first**

In `opentofu/aws/eks/configure/workflows.tm.hcl`, in both `script "deploy"` and `script "preview"`, insert as the **first** command of the job:

```hcl
      # The vault provider (openbao.tf) verifies OpenBao against the CA chain,
      # which must be on disk before `tofu init`. Same step the management
      # stack runs; .tls/ is gitignored.
      [
        "bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run",
        "bash", "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh", "ca",
        "--root-ca-secret-name", global.ca_chain_secret_name,
        "--ca-output-file", ".tls/ca.pem",
        "--region", global.region,
        "--profile", global.profile,
      ],
```

Then in `opentofu/aws/eks/init/workflows.tm.hcl`, job `stage2-cilium-and-flux` (the one whose commands `cd ../configure && ... init` and `... apply`), insert this as the **first** command:

```hcl
      # The configure stack's vault provider needs the CA chain on disk before
      # `tofu init`. Same step the management stack runs; configure/.tls/ is
      # gitignored.
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "-c", "cd ../configure && bash '${terramate.root.path.fs.absolute}/scripts/openbao-config.sh' ca --root-ca-secret-name '${global.ca_chain_secret_name}' --ca-output-file .tls/ca.pem --region '${global.region}' --profile '${global.profile}'"],
```

And in the `stage2-destroy-addons` job of the same file (its single command calls `scripts/destroy-stage2.sh attempt .../opentofu/aws/eks/configure ...`), insert the same `ca` command as the first command of that job too — `tofu destroy` in the configure directory still has to configure the vault provider, and in a `--reverse destroy` OpenBao is still up at that point (the OpenBao stacks come later in the reverse walk). Without the CA the destroy would abort at provider configuration; `destroy-stage2.sh attempt` tolerates that, but a clean teardown is better than a tolerated failure.

- [ ] **Step 6: Validate**

```bash
tofu fmt -recursive opentofu/aws/eks/configure
(cd opentofu/aws/eks/configure && tofu init -backend=false >/dev/null && tofu validate)
python3 scripts/flux-schema/check-substitution.py
```

Expected: valid. `check-substitution.py` **fails** at this point on `${cert_manager_approle_id}` and `${openbao_snapshot_secret}`, which Task 7 removes from the manifests — that is the expected, temporary state. Do not commit Task 6 and Task 7 separately if you want every commit green; the split here is for readability. If you do commit separately, note the known failure in the commit body.

- [ ] **Step 7: Commit**

```bash
git add opentofu/aws/eks/configure opentofu/aws/eks/init/workflows.tm.hcl
git commit -m "feat(eks): configure stack owns the jwt/aws-0 auth mount and its three roles

The EKS OIDC issuer changes on every rebuild and is only known after
eks/init, so the cluster's JWT mount is created here, with roles bound to
the cert-manager, external-secrets and openbao-snapshot ServiceAccounts
and audience 'openbao'. The approle Secret and Flux variable go, and the
ConfigMap gains openbao_snapshot_bucket in place of openbao_snapshot_secret.
check-substitution fails until the manifests follow in the next commit."
```

---

### Task 7: Kubernetes manifests — the neutral `openbao` Service, JWT consumers, secrets removed, Tailscale ACL

**Files:**
- Create: `security/base/openbao-endpoint/local/kustomization.yaml`, `security/base/openbao-endpoint/local/service.yaml`
- Create: `security/base/openbao-endpoint/remote/kustomization.yaml`, `security/base/openbao-endpoint/remote/service.yaml`
- Modify: `security/aws-0/openbao/kustomization.yaml`, `security/gcp-0/openbao/kustomization.yaml`
- Modify: `security/aws-0/openbao/openbao-clusterissuer.yaml`, `security/gcp-0/openbao/openbao-clusterissuer.yaml`
- Delete: `security/aws-0/openbao/openbao-approle-externalsecret.yaml`, `security/gcp-0/openbao/openbao-approle-externalsecret.yaml`
- Modify: `security/aws-0/openbao/openbao-ca-externalsecret.yaml:21`, `observability/base/victoria-metrics-k8s-stack/externalsecret-openbao-ca.yaml:18`
- Modify: `clusters/aws-0/security/security-openbao.yaml`
- Delete: `security/base/openbao-snapshot/external-secrets.yaml`
- Modify: `security/base/openbao-snapshot/kustomization.yaml`, `security/base/openbao-snapshot/snapshot-cronjob.yaml`, `security/base/openbao-snapshot/network-policy.yaml`
- Modify: `scripts/flux-schema/render-bundle.py:92,106`
- Modify: `opentofu/shared/tailscale/main.tf:16-35`

**Deviation from the design, stated:** the design says a per-cluster Flux variable `openbao_target` "selects the row" (local vs remote form of the Service). Flux `postBuild` substitutes strings; it cannot choose which manifest renders. So the *form* is a committed overlay choice — each cluster's `openbao/kustomization.yaml` lists `local` or `remote` — and the *target address* is the Flux variable `openbao_target_ip`. Switching a cluster from local to remote is a one-line commit, which is the same gate ADR-0024 uses for ZITADEL's `spec.suspend`.

- [ ] **Step 1: The two forms of the Service**

`security/base/openbao-endpoint/local/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yaml
```

`security/base/openbao-endpoint/local/service.yaml`:

```yaml
# The ONE name every consumer on this cluster uses for OpenBao:
# https://openbao.security.svc.cluster.local:8200. Consumers never change;
# what this name points at does.
#
# LOCAL form: this cluster is in the same cloud as the active OpenBao, so the
# name is a plain CNAME to the internal load balancer's DNS record and traffic
# never leaves the VPC. The sibling ../remote/ is the form for a cluster in the
# OTHER cloud (Tailscale egress). A cluster's security/<cluster>/openbao/
# kustomization.yaml lists exactly one of the two.
#
# TLS: clients connect with this Service name as the server name, so OpenBao's
# server certificate carries it as a SAN (PKI & Secrets page, "Building the
# chain").
apiVersion: v1
kind: Service
metadata:
  name: openbao
  namespace: security
spec:
  type: ExternalName
  externalName: bao.${private_domain_name}
  ports:
    - name: https
      port: 8200
      protocol: TCP
```

`security/base/openbao-endpoint/remote/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yaml
```

`security/base/openbao-endpoint/remote/service.yaml`:

```yaml
# REMOTE form of the openbao Service (see ../local/service.yaml for the name
# contract). This cluster's pods cannot route to the other cloud's VPC -- pods
# are not tailnet devices -- so the Tailscale operator proxies the connection:
# an ExternalName Service annotated with a tailnet-reachable IP is rewritten by
# the operator to point at its egress ProxyGroup, whose pods carry the traffic
# over the tailnet to that cloud's subnet router and on to the address.
#
# ${openbao_target_ip} is one of the active OpenBao's FIXED internal NLB
# addresses (opentofu/aws/openbao/cluster: `tofu output nlb_private_ips`),
# set per cluster in its configure stack's vars ConfigMap. Failover = change
# that variable.
#
# The ProxyGroup `ts-proxies` (security/base/tailscale-operator/proxygroup.yaml)
# is tagged tag:k8s; opentofu/shared/tailscale/main.tf admits tag:k8s to the
# advertised VPC CIDRs on 8200 for exactly this path.
apiVersion: v1
kind: Service
metadata:
  name: openbao
  namespace: security
  annotations:
    tailscale.com/tailnet-ip: "${openbao_target_ip}"
    tailscale.com/proxy-group: ts-proxies
spec:
  type: ExternalName
  # Overwritten by the operator with the ProxyGroup's Service name.
  externalName: placeholder
  ports:
    - name: https
      port: 8200
      protocol: TCP
```

- [ ] **Step 2: Both overlays list the local form; the ClusterIssuers switch to JWT and the neutral name**

`security/aws-0/openbao/kustomization.yaml` — replace the `resources:` list with:

```yaml
resources:
  - ../../base/openbao-endpoint/local
  - clustersecretstore.yaml
  - openbao-ca-externalsecret.yaml
  - openbao-clusterissuer.yaml
```

`security/gcp-0/openbao/kustomization.yaml` — same list. Add this comment above `resources:` in **both** files:

```yaml
# `openbao-endpoint/local` because this cluster consumes the OpenBao in its own
# cloud. A cluster consuming the OTHER cloud's active OpenBao lists
# `../../base/openbao-endpoint/remote` instead and sets openbao_target_ip in
# its configure stack -- see the cross-cloud failover guide.
```

```bash
git rm security/aws-0/openbao/openbao-approle-externalsecret.yaml security/gcp-0/openbao/openbao-approle-externalsecret.yaml
```

Replace `security/aws-0/openbao/openbao-clusterissuer.yaml` with:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao
  namespace: security
spec:
  vault:
    # The neutral in-cluster name (security/base/openbao-endpoint). Was
    # bao.${private_domain_name}; the Service now decides where that goes.
    server: https://openbao.security.svc.cluster.local:8200
    # No `namespace`: the PKI mount and the auth mount both live in the root
    # namespace. See opentofu/aws/openbao/management/namespaces.tf for why the
    # earlier `admin/pki` layout was dropped.
    path: pki_private_issuer/sign/ogenki
    # Synced from the same Secrets Manager entry the management stack's CA step
    # reads, so rotating the intermediate does not require editing a manifest.
    # Resolved in cert-manager's cluster resource namespace (`security`).
    caBundleSecretRef:
      name: openbao-ca
      key: ca.crt
    auth:
      # A projected ServiceAccount token, not an AppRole. cert-manager requests
      # a short-lived token for its own ServiceAccount with the audience the
      # JWT role binds, and POSTs {jwt, role} to the mount -- which is exactly
      # the JWT method's login payload, so `kubernetes` here targets a `jwt`
      # mount. Nothing long-lived is stored anywhere. The mount is created by
      # opentofu/aws/eks/configure/openbao.tf.
      kubernetes:
        mountPath: /v1/auth/jwt/${cluster_name}
        role: cert-manager
        serviceAccountRef:
          name: cert-manager
          audiences:
            - openbao
```

Replace `security/gcp-0/openbao/openbao-clusterissuer.yaml` with:

```yaml
# Issues private certificates for this cluster from the OpenBao the openbao
# Service points at (security/base/openbao-endpoint). In GCP-only mode that is
# this cloud's own OpenBao; consuming the AWS active instance is the remote form
# of that Service.
#
# The chain behind it: an OFFLINE root signed the intermediate with openssl, the
# intermediate was imported into OpenBao as its issuer, and this role signs
# leaves from that. The root's private key has never been on a networked system.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao
  namespace: security
spec:
  vault:
    server: https://openbao.security.svc.cluster.local:8200
    # No `namespace`: the PKI mount and the auth mount both live in OpenBao's
    # root namespace, matching AWS.
    path: pki_private_issuer/sign/ogenki
    caBundleSecretRef:
      name: openbao-ca
      key: ca.crt
    auth:
      # JWT method, same as aws-0 -- see the comment there. The mount is created
      # by opentofu/gcp/gke/configure/openbao.tf. This replaced a pinned AppRole
      # role_id whose only reason to exist was that cert-manager takes roleId
      # as a literal string.
      kubernetes:
        mountPath: /v1/auth/jwt/${cluster_name}
        role: cert-manager
        serviceAccountRef:
          name: cert-manager
          audiences:
            - openbao
```

- [ ] **Step 3: The CA ExternalSecrets read the chain entry**

In `security/aws-0/openbao/openbao-ca-externalsecret.yaml`, replace `key: certificates/${private_domain_name}/root-ca` with `key: certificates/${private_domain_name}/ca-chain`, and replace the comment above it (`# Per-cloud: priv.aws.ogenki.io on aws-0 ...` three lines) with:

```yaml
        # Certificates only -- intermediate then root -- under the `ca` key.
        # The former `root-ca` entry, which also held the ROOT private key, is
        # gone: the root is offline and the intermediate lives in
        # certificates/<domain>/intermediate-ca, which nothing in-cluster reads.
```

In `observability/base/victoria-metrics-k8s-stack/externalsecret-openbao-ca.yaml`, replace `key: certificates/${private_domain_name}/root-ca` with `key: certificates/${private_domain_name}/ca-chain` and, in the comment two lines above, replace `Same secret the OpenTofu management stack reads to` / `# build the PKI chain.` with `Same entry the OpenTofu management stack's CA step` / `# writes to disk for the vault provider.`

- [ ] **Step 4: The Flux Kustomization stops substituting from a Secret**

In `clusters/aws-0/security/security-openbao.yaml`, replace:

```yaml
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
      # ${cert_manager_approle_id} for the openbao ClusterIssuer's roleId.
      # cert-manager takes roleId as a plain string with no secretRef option, so
      # a generated value has to arrive through substitution.
      - kind: Secret
        name: cert-manager-openbao-approle
```

with:

```yaml
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
    # No Secret source any more. The ClusterIssuer used to take an AppRole
    # roleId out of a Secret this Kustomization's own ExternalSecret created,
    # so a fresh cluster's first reconcile necessarily failed. JWT auth needs
    # no generated value: the role name is a literal and the credential is a
    # projected ServiceAccount token.
```

- [ ] **Step 5: The snapshot CronJob authenticates with a projected token and stops reading a Secret**

```bash
git rm security/base/openbao-snapshot/external-secrets.yaml
```

In `security/base/openbao-snapshot/kustomization.yaml`, remove the `- external-secrets.yaml` line.

In `security/base/openbao-snapshot/snapshot-cronjob.yaml`:

Add to the `volumes:` list (after the `openbao-ca` entry):

```yaml
            # The credential. A projected ServiceAccount token with the audience
            # the JWT role binds and a 10-minute lifetime; the kubelet rotates
            # it. Nothing here comes from a secret store any more.
            - name: openbao-token
              projected:
                sources:
                  - serviceAccountToken:
                      path: token
                      audience: openbao
                      expirationSeconds: 600
```

Replace the `env:` list's `VAULT_CACERT`, `HOME` and `CLOUD` entries **and** the `envFrom:` block with:

```yaml
              env:
                # No VAULT_SKIP_VERIFY. The job goes through the neutral
                # in-cluster name, which is a SAN on the server certificate, so
                # the CA is enough and this workload verifies TLS like everything
                # else.
                - name: VAULT_CACERT
                  value: /etc/openbao/tls/ca.crt
                - name: VAULT_ADDR
                  value: https://openbao.security.svc.cluster.local:8200
                - name: HOME
                  value: /snapshot
                # Selects the cloud branch inside openbao-snapshot.sh (aws | gcp).
                # gcp-0 patches this to "gcp".
                - name: CLOUD
                  value: "aws"
                # The lineage's snapshot bucket, per cluster (region-prefixed on
                # AWS, project-prefixed on GCP).
                - name: BUCKET_NAME
                  value: ${openbao_snapshot_bucket}
                # JWT login: mount, role and where the projected token is.
                - name: OPENBAO_JWT_MOUNT
                  value: jwt/${cluster_name}
                - name: OPENBAO_JWT_ROLE
                  value: openbao-snapshot
                - name: OPENBAO_JWT_PATH
                  value: /var/run/secrets/openbao/token
```

Change `image: ghcr.io/smana/openbao-snapshot:v0.1.0` to `image: ghcr.io/smana/openbao-snapshot:v0.2.0`.

Add to `volumeMounts:`:

```yaml
                - mountPath: /var/run/secrets/openbao
                  name: openbao-token
                  readOnly: true
```

- [ ] **Step 6: Network policy admits the egress proxy path**

In `security/base/openbao-snapshot/network-policy.yaml`, after the `toCIDR: [${openbao_cidr}]` rule, add:

```yaml
    # The same 8200, when the openbao Service is in its REMOTE form
    # (security/base/openbao-endpoint/remote): the ExternalName then resolves
    # to the Tailscale operator's egress ProxyGroup, so the packet's first hop
    # is a proxy pod in the tailscale namespace, not the load balancer. Harmless
    # in the local form -- no traffic matches it.
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: tailscale
            k8s:tailscale.com/parent-resource: ts-proxies
      toPorts:
        - ports:
            - port: "8200"
              protocol: TCP
```

- [ ] **Step 7: The bundle renderer's fixture variables**

In `scripts/flux-schema/render-bundle.py`, delete the line `"cert_manager_approle_id": "random",`. Replace the `openbao_snapshot_secret` entry and its five comment lines with:

```python
    # The lineage's snapshot bucket, consumed as BUCKET_NAME by the snapshot
    # CronJob. AWS value; gcp-0's ConfigMap carries a project-prefixed name.
    "openbao_snapshot_bucket": "eu-west-3-ogenki-openbao-snapshot",
    # security/base/openbao-endpoint/remote: the active OpenBao's fixed NLB
    # address a remote cluster proxies to. Only gcp-0 applies that directory.
    "openbao_target_ip": "10.0.15.250",
```

- [ ] **Step 8: Tailscale ACL — proxies may reach the VPCs on 8200**

In `opentofu/shared/tailscale/main.tf`, inside `acls = concat(`, replace the second array literal:

```hcl
      [
        { action = "accept", src = ["autogroup:member"], dst = ["autogroup:member:*"] },
        { action = "accept", src = ["tag:k8s-operator"], dst = ["tag:k8s:*", "tag:admin:*"] },
      ]
```

with:

```hcl
      [
        { action = "accept", src = ["autogroup:member"], dst = ["autogroup:member:*"] },
        { action = "accept", src = ["tag:k8s-operator"], dst = ["tag:k8s:*", "tag:admin:*"] },
        # The operator's egress ProxyGroup pods (tag:k8s) carrying a remote
        # cluster's OpenBao traffic to the other cloud's internal load balancer
        # -- security/base/openbao-endpoint/remote. Port 8200 only, to every
        # advertised CIDR: which cloud is active is a per-cluster variable, and
        # the ACL should not have to know.
        {
          action = "accept"
          src    = ["tag:k8s"]
          dst    = [for c in flatten(values(var.advertised_routes)) : "${c}:8200"]
        },
      ]
```

- [ ] **Step 9: Validate**

```bash
./scripts/validate-manifests.sh
python3 scripts/flux-schema/check-substitution.py
python3 scripts/flux-schema/test-check-substitution.py
tofu fmt -recursive opentofu/shared/tailscale
(cd opentofu/shared/tailscale && tofu init -backend=false >/dev/null && tofu validate)
grep -rn "approle\|root-ca\|openbao_snapshot_secret\|cert_manager_approle" security/ observability/ clusters/ scripts/flux-schema/ --include='*.yaml' --include='*.py'; echo "grep-exit=$?"
```

Expected, and **one of these is a deliberate failure**:

- `flux schema validate` → `Invalid: 0, Skipped: 0`, and `polaris` clean.
- `check-substitution.py` → **exit 1, with exactly one finding**:
  `clusters/gcp-0/security/security-openbao-snapshot.yaml` applies
  `${openbao_snapshot_bucket}`, which `gke-gcp-0-vars` does not define yet.
  This is **expected and correct**. Step 5 moves that variable into the *shared*
  base `security/base/openbao-snapshot/snapshot-cronjob.yaml`, which gcp-0's
  overlay also consumes — and gcp-0's ConfigMap is **Task 11's** Step 3. Any
  other finding is a real defect. Do **not** "fix" this one by editing
  `opentofu/gcp/gke/configure/`: that is Task 11's file, and touching it here
  splits one change across two tasks.
  Because `validate-manifests.sh` runs this gate **first** and stops on it, run
  the remaining gates by hand to prove they pass: `scripts/flux-schema/gen-catalog.sh`,
  `render-bundle.py .bundle`, `flux schema validate --config .fluxschema.yml`,
  and `polaris audit --set-exit-code-on-danger`.
- `test-check-substitution.py` → exit 0. `validate-links.sh` → exit 0. Both
  `tofu validate`s → valid. `fmt` → 0.
- The final grep prints only comment lines that *explain the removal*; read each
  and confirm none is a live `${var}` or a surviving manifest reference.

**The branch is therefore red on that one finding from Task 7 until Task 11
lands.** They are in the same branch and the same pull request, so nothing ships
in that state — but do not treat the red as done-and-acceptable, and re-run the
full suite after Task 11.

- [ ] **Step 10: Commit**

```bash
git add security observability clusters scripts/flux-schema/render-bundle.py opentofu/shared/tailscale
git commit -m "feat(security): consumers reach OpenBao by one in-cluster name and authenticate with cluster JWTs

A neutral openbao ExternalName Service in security/, in a local form (CNAME
to the cloud's internal LB) and a remote form (Tailscale operator egress to
a fixed NLB address). Both ClusterIssuers use it and log in with a projected
cert-manager ServiceAccount token against jwt/<cluster>; the snapshot
CronJob does the same and reads BUCKET_NAME from openbao_snapshot_bucket.
The AppRole ExternalSecrets, the snapshot Secret and the Secret-sourced Flux
variable are gone; the CA ExternalSecrets read the certificates-only
ca-chain entry. Tailscale admits tag:k8s to the VPC CIDRs on 8200."
```

---

### Task 8: GCP lineage stack — bucket, node and drill identities, Storage Transfer mirror, GitHub WIF

**Files:**
- Create: `opentofu/gcp/openbao/lineage/stack.tm.hcl`
- Create: `opentofu/gcp/openbao/lineage/backend.tf`
- Create: `opentofu/gcp/openbao/lineage/versions.tf`
- Create: `opentofu/gcp/openbao/lineage/providers.tf`
- Create: `opentofu/gcp/openbao/lineage/variables.tf`
- Create: `opentofu/gcp/openbao/lineage/variables.tfvars`
- Create: `opentofu/gcp/openbao/lineage/main.tf`
- Create: `opentofu/gcp/openbao/lineage/transfer.tf`
- Create: `opentofu/gcp/openbao/lineage/github-wif.tf`
- Create: `opentofu/gcp/openbao/lineage/outputs.tf`
- Create: `opentofu/gcp/openbao/lineage/workflows.tm.hcl`
- Create: `opentofu/gcp/openbao/lineage/trivy.yaml` (copy of `opentofu/gcp/openbao/management/trivy.yaml`)
- Create: `opentofu/gcp/openbao/lineage/.trivyignore.yaml` (copy the header and
  `misconfigurations: []` from `opentofu/gcp/openbao/cluster/.trivyignore.yaml`).
  **This file must exist even though it is empty.** The `deploy` and `preview`
  scripts you copy in Step 6 run
  `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .`, and trivy
  exits **FATAL** on a missing ignorefile — so without it
  `TM_CLOUD=gcp terramate script run deploy` on this stack dies before planning
  a single resource, which is what the live Task 15 does. Both GCP sibling
  stacks carry this file and say exactly this in their own header comment.
  `trivy.yaml` cannot substitute for it: that file configures the scanner and
  can only *point at* an ignorefile, never carry ignore rules itself.
- Delete: `security/gcp-0/openbao-snapshot/gcs-bucket.yaml`
- Modify: `security/gcp-0/openbao-snapshot/kustomization.yaml`

The GCP seal key is **not** here: the key ring and key are already hand-created prerequisites read by data source (`opentofu/gcp/openbao/cluster/kms.tf`), which is exactly the property the AWS key lacked.

- [ ] **Step 1: Scaffolding**

`stack.tm.hcl`:

```hcl
stack {
  name        = "GCP OpenBao lineage"
  description = "What a rebuilt GCP OpenBao needs to come back, plus the cross-cloud plumbing: the snapshot bucket (also the mirror target for AWS snapshots), the node and CI identities, the Storage Transfer job pulling S3, and the GitHub WIF pool. Persistent -- never destroyed by the default destroy script"
  id          = "8e1a52d4-3b7f-4c66-9a0d-2f5e7c1b9a3d"

  # No `after`: nothing here needs the network. openbao/cluster lists this stack
  # in its own `after`.

  tags = [
    "gcp",
    "openbao",
    "openbao-lineage",
    "security",
    "persistent",
    # See opentofu/gcp/network/stack.tm.hcl -- REMOVE THIS TAG AND THE GUARDS
    # once GCP works end to end.
    "opt-in",
  ]
}
```

`backend.tf`:

```hcl
# GCP state lives in GCS -- see opentofu/gcp/network/backend.tf and ADR-0018.
terraform {
  backend "gcs" {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/openbao/lineage"
  }
}
```

`versions.tf`:

```hcl
terraform {
  required_version = ">= 1.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.17"
    }
  }
}
```

`providers.tf`:

```hcl
provider "google" {
  project = var.project_id
  region  = var.region
}
```

`variables.tf`:

```hcl
variable "project_id" {
  description = "GCP project holding OpenBao and its snapshot bucket"
  type        = string
}

variable "region" {
  description = "GCP region for the bucket"
  type        = string
  default     = "europe-west4"
}

variable "snapshot_bucket_name" {
  description = "GCS bucket for raft snapshots and the mirror of the AWS bucket. Empty derives <project_id>-ogenki-openbao-snapshot, the name the Crossplane bucket already has (project-prefixed: GCS names are global, and the Crossplane IAM condition keyed on that prefix)."
  type        = string
  default     = ""
}

variable "aws_snapshot_bucket_name" {
  description = "The AWS lineage's snapshot bucket, pulled by the Storage Transfer job"
  type        = string
  default     = "eu-west-3-ogenki-openbao-snapshot"
}

variable "aws_mirror_role_arn" {
  description = "ARN of the AWS role the Storage Transfer service agent assumes to read the S3 bucket (opentofu/shared/aws-gcp-federation, `openbao-snapshot-mirror`). Empty disables the transfer job -- the federation stack needs this stack's transfer_agent_subject_id output first, so the two are applied in two passes."
  type        = string
  default     = ""
}

variable "mirror_start_hour_utc" {
  description = "Hour (UTC) the daily mirror runs. One hour after the 04:00 UTC snapshot CronJob."
  type        = number
  default     = 5
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflows may impersonate the drill service account"
  type        = string
  default     = "Smana/cloud-native-ref"
}
```

`variables.tfvars`:

```hcl
project_id = "ogenki-435905"
# aws_mirror_role_arn is set in Task 16, after the federation stack has created
# the role. Until then the transfer job is not created.
```

- [ ] **Step 2: `main.tf` — bucket and identities**

```hcl
locals {
  snapshot_bucket_name = var.snapshot_bucket_name == "" ? format("%s-ogenki-openbao-snapshot", var.project_id) : var.snapshot_bucket_name
}

# The snapshot bucket, adopted from the Crossplane MR that used to live in
# security/gcp-0/openbao-snapshot/gcs-bucket.yaml (imported in Task 15). It
# moves for the same reason the AWS one does -- rehydrate reads it before the
# cluster exists -- plus one more: it is the MIRROR target for AWS snapshots,
# and the DR promise cannot depend on gcp-0 having been built once.
resource "google_storage_bucket" "snapshot" {
  name                        = local.snapshot_bucket_name
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  # Snapshots are small; keep the history the AWS bucket keeps.
  lifecycle_rule {
    condition {
      age = 120
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    app = "openbao"
  }
}

# The OpenBao node's identity. Created HERE, not in the cluster stack, so its
# unique ID is stable: the AWS role `openbao-standby-seal` trusts that ID, and a
# service account recreated with the cluster would get a new one and silently
# break the trust. The cluster stack reads it through remote state.
resource "google_service_account" "openbao_node" {
  account_id   = "openbao-node"
  display_name = "OpenBao node (lineage identity; trusted by the AWS seal role)"
  project      = var.project_id
}

# The CI drill's identity, impersonated from GitHub Actions through the WIF pool
# in github-wif.tf. Reads the bucket, nothing else.
resource "google_service_account" "openbao_drill" {
  account_id   = "openbao-drill"
  display_name = "OpenBao restore drill (GitHub Actions)"
  project      = var.project_id
}

resource "google_storage_bucket_iam_member" "drill_reader" {
  bucket = google_storage_bucket.snapshot.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.openbao_drill.email}"
}
```

- [ ] **Step 3: `transfer.tf` — the S3 → GCS mirror**

```hcl
# Storage Transfer Service pulls the AWS lineage's bucket into this one.
#
# Why STS rather than a second upload from the snapshot CronJob: the CronJob
# runs in aws-0, whose OIDC issuer changes on every rebuild, so a GCP Workload
# Identity Pool trusting it would need re-federating after each eks/init. The
# transfer service agent's identity is deterministic per project, so the AWS
# side can trust it once (opentofu/shared/aws-gcp-federation, role
# `openbao-snapshot-mirror`) and the trust never follows a rebuilt cluster.
#
# Federated identity: STS presents a Google-issued token for its service agent
# to AWS STS and assumes var.aws_mirror_role_arn. No key at rest on either side.
data "google_storage_transfer_project_service_account" "default" {
  project = var.project_id
}

# The service agent writes into the sink bucket.
resource "google_storage_bucket_iam_member" "transfer_sink" {
  bucket = google_storage_bucket.snapshot.name
  role   = "roles/storage.legacyBucketWriter"
  member = "serviceAccount:${data.google_storage_transfer_project_service_account.default.email}"
}

resource "google_storage_transfer_job" "s3_mirror" {
  count = var.aws_mirror_role_arn == "" ? 0 : 1

  description = "Mirror OpenBao raft snapshots from the AWS lineage bucket"
  project     = var.project_id

  transfer_spec {
    aws_s3_data_source {
      bucket_name = var.aws_snapshot_bucket_name
      role_arn    = var.aws_mirror_role_arn
    }

    gcs_data_sink {
      bucket_name = google_storage_bucket.snapshot.name
    }

    transfer_options {
      # Snapshots are immutable objects with unique names; never overwrite and
      # never delete on the sink -- the sink also holds GCP-taken snapshots.
      overwrite_objects_already_existing_in_sink = false
      delete_objects_unique_in_sink              = false
      delete_objects_from_source_after_transfer  = false
    }
  }

  schedule {
    schedule_start_date {
      year  = 2026
      month = 9
      day   = 1
    }
    start_time_of_day {
      hours   = var.mirror_start_hour_utc
      minutes = 0
      seconds = 0
      nanos   = 0
    }
    # Daily. Tighten to "3600s" for the production posture (hourly snapshots).
    repeat_interval = "86400s"
  }

  depends_on = [google_storage_bucket_iam_member.transfer_sink]
}
```

- [ ] **Step 4: `github-wif.tf` — the drill's way into GCP**

```hcl
# GitHub Actions -> GCP, for the weekly restore drill's mirror-freshness check.
# The drill reads the newest object name and size on both sides and asserts
# they match; that needs a listing of this bucket and nothing else.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "Federates GitHub Actions OIDC tokens for ${var.github_repository}"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only this repository, only main. A fork or a branch presents a different
  # repository/ref and is refused at the pool.
  attribute_condition = "assertion.repository == \"${var.github_repository}\" && assertion.ref == \"refs/heads/main\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "drill_wif" {
  service_account_id = google_service_account.openbao_drill.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
```

- [ ] **Step 5: `outputs.tf`**

```hcl
output "snapshot_bucket_name" {
  description = "GCS snapshot bucket, also the mirror target"
  value       = google_storage_bucket.snapshot.name
}

output "openbao_node_sa_email" {
  description = "The node's service account. Consumed by opentofu/gcp/openbao/cluster through remote state."
  value       = google_service_account.openbao_node.email
}

output "openbao_node_sa_unique_id" {
  description = "Set this as gcp_openbao_standby_sa_unique_id in opentofu/shared/aws-gcp-federation/variables.tfvars: the AWS seal role trusts this subject."
  value       = google_service_account.openbao_node.unique_id
}

output "transfer_agent_subject_id" {
  description = "Set this as gcp_transfer_agent_subject_id in opentofu/shared/aws-gcp-federation/variables.tfvars: the AWS mirror role trusts this subject."
  value       = data.google_storage_transfer_project_service_account.default.subject_id
}

output "drill_workload_identity_provider" {
  description = "Set this as the GCP_DRILL_WIF_PROVIDER repository variable for the drill workflow"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "drill_service_account_email" {
  description = "Set this as the GCP_DRILL_SERVICE_ACCOUNT repository variable for the drill workflow"
  value       = google_service_account.openbao_drill.email
}
```

- [ ] **Step 6: `workflows.tm.hcl`** — the GCP stacks gate on `${global.cloud_gate}` for every script (see `opentofu/gcp/openbao/cluster/workflows.tm.hcl`). Copy that file's `deploy`, `preview`, `drift detect`, `drift reconcile`, `opentofu render` and `init` scripts verbatim, changing only the `name`/`description` strings to say `GCP OpenBao Lineage`. Replace its `destroy` script with:

```hcl
script "destroy" {
  name        = "GCP OpenBao Lineage Destroy (guarded, opt-in)"
  description = "Destroy the snapshot bucket, identities, transfer job and WIF pool. Requires TM_LINEAGE_DESTROY=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        if [ "$${TM_LINEAGE_DESTROY:-}" != "true" ]; then
          echo "[skip] opentofu/gcp/openbao/lineage destroy: this stack holds the GCS snapshot"
          echo "       bucket (the mirror of every AWS snapshot) and the node identity the AWS"
          echo "       seal role trusts. Set TM_LINEAGE_DESTROY=true only if that is genuinely"
          echo "       what you want."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
        ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}
```

- [ ] **Step 7: Remove the Crossplane bucket**

```bash
cp opentofu/gcp/openbao/management/trivy.yaml opentofu/gcp/openbao/lineage/trivy.yaml
git rm security/gcp-0/openbao-snapshot/gcs-bucket.yaml
```

In `security/gcp-0/openbao-snapshot/kustomization.yaml`, remove `- gcs-bucket.yaml` and replace the header comment with:

```yaml
# The GCS bucket used to be a Crossplane MR here; it is now an OpenTofu resource
# in opentofu/gcp/openbao/lineage, because rehydrate reads it before this
# cluster exists and because it mirrors the AWS bucket whether or not gcp-0 is
# ever built. The MR carried no `Delete` policy, so removing it orphaned the
# bucket and the lineage stack imported it. The GCPWorkloadIdentity stays: the
# CronJob still writes this cluster's own snapshots into it.
```

- [ ] **Step 8: Validate**

```bash
tofu fmt -recursive opentofu/gcp/openbao/lineage
(cd opentofu/gcp/openbao/lineage && tofu init -backend=false >/dev/null && tofu validate)
(cd opentofu/gcp/openbao/lineage && trivy config --exit-code=1 --config trivy.yaml .)
./scripts/validate-manifests.sh
```

Expected: valid; trivy exit 0; manifests `Invalid: 0, Skipped: 0`.

Trivy will flag the bucket for no CMEK (`GCP-0066`) and no versioning
(`GCP-0078`). Suppress both with **inline `#trivy:ignore:<ID>` comments above
`google_storage_bucket.snapshot`**, one line of justification each — that is
this repo's idiom for a finding with a single owning resource, because it keeps
the reason next to the code (see `opentofu/aws/openbao/lineage/kms.tf`). Put ids
in `.trivyignore.yaml` only for findings with no single owner. Do **not** try to
put ignore rules in `trivy.yaml`: it has no such mechanism, only an
`ignorefile:` pointer.

- [ ] **Step 9: Commit**

```bash
git add opentofu/gcp/openbao/lineage security/gcp-0/openbao-snapshot
git commit -m "feat(openbao): GCP lineage stack -- snapshot bucket, node and drill identities, S3 mirror, GitHub WIF

The GCS bucket moves from Crossplane so it exists before the cluster and
regardless of whether gcp-0 was ever built: it is where AWS snapshots are
mirrored by a Storage Transfer job authenticating to S3 with federated
identity. The node's service account lives here so the AWS seal role can
trust a stable unique ID. A WIF pool lets the weekly drill read the bucket."
```

---

### Task 9: Federation stack — `accounts.google.com` provider, the standby-seal and mirror roles

**Files:**
- Create: `opentofu/shared/aws-gcp-federation/google-identity.tf`
- Modify: `opentofu/shared/aws-gcp-federation/variables.tf`
- Modify: `opentofu/shared/aws-gcp-federation/variables.tfvars`
- Modify: `opentofu/shared/aws-gcp-federation/outputs.tf`
- Modify: `opentofu/shared/aws-gcp-federation/stack.tm.hcl` (description)

Both roles are created only when their GCP subject is known (`count`), so an AWS-only deploy that has never applied the GCP lineage still applies cleanly.

- [ ] **Step 1: Variables**

Append to `variables.tf`:

```hcl
# --- Google-issued identities (not GKE ServiceAccounts) ----------------------
#
# Two things on GCP need to reach AWS with a token Google signs directly, not
# through the GKE issuer above: the OpenBao standby VM (a Compute Engine
# identity token, to use the AWS KMS seal) and the Storage Transfer service
# agent (to read the S3 snapshot bucket). Both trust the same
# `accounts.google.com` provider and are pinned by subject.

variable "gcp_openbao_standby_sa_unique_id" {
  description = "Unique ID of the openbao-node service account (opentofu/gcp/openbao/lineage output openbao_node_sa_unique_id). Empty skips the standby-seal role."
  type        = string
  default     = ""
}

variable "gcp_transfer_agent_subject_id" {
  description = "Subject ID of the project's Storage Transfer service agent (opentofu/gcp/openbao/lineage output transfer_agent_subject_id). Empty skips the mirror role."
  type        = string
  default     = ""
}

variable "openbao_seal_key_alias" {
  description = "Alias of the multi-region OpenBao seal key (opentofu/aws/openbao/lineage). Granted through the kms:ResourceAliases condition, so the key need not exist when this stack applies."
  type        = string
  default     = "alias/openbao-seal"
}

variable "openbao_snapshot_bucket_name" {
  description = "The AWS lineage's snapshot bucket the mirror role may read"
  type        = string
  default     = "eu-west-3-ogenki-openbao-snapshot"
}

variable "openbao_snapshot_key_alias" {
  description = "Alias of the KMS key encrypting the snapshot bucket"
  type        = string
  default     = "alias/xplane-openbao-snapshot"
}
```

Append to `variables.tfvars`:

```hcl
# Filled in Task 16 from `tofu output` in opentofu/gcp/openbao/lineage. Empty
# until then, which skips the two Google-identity roles.
gcp_openbao_standby_sa_unique_id = ""
gcp_transfer_agent_subject_id    = ""
```

- [ ] **Step 2: `google-identity.tf`**

```hcl
# AWS trusts tokens Google signs for two specific principals.
#
# This is a SECOND OIDC provider next to the GKE one in main.tf, and it is a
# different kind of token: `accounts.google.com` issues identity tokens for
# Google service accounts (a Compute Engine VM asking the metadata server, or a
# Google-managed service agent), where the GKE provider validates Kubernetes
# ServiceAccount tokens. Same pattern -- no material at rest, short-lived
# credentials from STS -- different issuer.
#
# Claim mapping AWS uses for Google tokens: `accounts.google.com:sub` is the
# service account's unique ID; `accounts.google.com:oaud` is the token's `aud`;
# `accounts.google.com:aud` is `azp`. Each role pins `sub` and `oaud`.
data "aws_caller_identity" "this" {}

data "tls_certificate" "google" {
  url = "https://accounts.google.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "google" {
  url = "https://accounts.google.com"
  # Every `aud` a trusted token may carry. The standby VM requests
  # sts.amazonaws.com; Storage Transfer's federated-identity tokens carry the
  # service agent's own subject ID as their audience.
  client_id_list  = compact(["sts.amazonaws.com", var.gcp_transfer_agent_subject_id])
  thumbprint_list = [data.tls_certificate.google.certificates[0].sha1_fingerprint]
}

# --- openbao-standby-seal ------------------------------------------------------
#
# Lets the GCP OpenBao node use the AWS multi-region seal key, so a snapshot
# taken under that seal restores on GCP during an AWS regional outage
# (design scenario A). The node fetches a Compute Engine identity token with
# audience sts.amazonaws.com every 50 minutes and the awskms seal exchanges it
# through the SDK's web-identity credential provider.
data "aws_iam_policy_document" "standby_seal_assume" {
  count = var.gcp_openbao_standby_sa_unique_id == "" ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.google.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:oaud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:sub"
      values   = [var.gcp_openbao_standby_sa_unique_id]
    }
  }
}

resource "aws_iam_role" "standby_seal" {
  count = var.gcp_openbao_standby_sa_unique_id == "" ? 0 : 1

  name               = "openbao-standby-seal"
  description        = "Assumed by the GCP OpenBao node (openbao-node service account) to use the AWS multi-region seal key"
  assume_role_policy = data.aws_iam_policy_document.standby_seal_assume[0].json
}

data "aws_iam_policy_document" "standby_seal" {
  statement {
    sid    = "SealKeyByAlias"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    # Every region: the standby names the replica region's copy.
    resources = ["arn:aws:kms:*:${data.aws_caller_identity.this.account_id}:key/*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [var.openbao_seal_key_alias]
    }
  }
}

resource "aws_iam_role_policy" "standby_seal" {
  count = var.gcp_openbao_standby_sa_unique_id == "" ? 0 : 1

  name   = "openbao-seal-key"
  role   = aws_iam_role.standby_seal[0].id
  policy = data.aws_iam_policy_document.standby_seal.json
}

# --- openbao-snapshot-mirror ---------------------------------------------------
#
# Lets Google's Storage Transfer Service read the AWS snapshot bucket to mirror
# it into GCS (opentofu/gcp/openbao/lineage/transfer.tf). Read-only on one
# bucket, plus decrypt on that bucket's key.
data "aws_iam_policy_document" "mirror_assume" {
  count = var.gcp_transfer_agent_subject_id == "" ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.google.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:oaud"
      values   = [var.gcp_transfer_agent_subject_id]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:sub"
      values   = [var.gcp_transfer_agent_subject_id]
    }
  }
}

resource "aws_iam_role" "mirror" {
  count = var.gcp_transfer_agent_subject_id == "" ? 0 : 1

  name               = "openbao-snapshot-mirror"
  description        = "Assumed by the GCP Storage Transfer service agent to mirror the OpenBao snapshot bucket into GCS"
  assume_role_policy = data.aws_iam_policy_document.mirror_assume[0].json
}

data "aws_iam_policy_document" "mirror" {
  statement {
    sid     = "ReadSnapshots"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      "arn:aws:s3:::${var.openbao_snapshot_bucket_name}",
      "arn:aws:s3:::${var.openbao_snapshot_bucket_name}/*",
    ]
  }

  statement {
    sid       = "DecryptSnapshotObjects"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:aws:kms:*:${data.aws_caller_identity.this.account_id}:key/*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [var.openbao_snapshot_key_alias]
    }
  }
}

resource "aws_iam_role_policy" "mirror" {
  count = var.gcp_transfer_agent_subject_id == "" ? 0 : 1

  name   = "openbao-snapshot-read"
  role   = aws_iam_role.mirror[0].id
  policy = data.aws_iam_policy_document.mirror.json
}
```

- [ ] **Step 3: Outputs and description**

Append to `outputs.tf`:

```hcl
output "openbao_standby_seal_role_arn" {
  description = "Set as aws_seal_role_arn in opentofu/gcp/openbao/cluster/variables.tfvars for a standby deploy. Empty until gcp_openbao_standby_sa_unique_id is set."
  value       = length(aws_iam_role.standby_seal) == 0 ? "" : aws_iam_role.standby_seal[0].arn
}

output "openbao_snapshot_mirror_role_arn" {
  description = "Set as aws_mirror_role_arn in opentofu/gcp/openbao/lineage/variables.tfvars. Empty until gcp_transfer_agent_subject_id is set."
  value       = length(aws_iam_role.mirror) == 0 ? "" : aws_iam_role.mirror[0].arn
}
```

In `stack.tm.hcl`, change `description` to `"AWS IAM OIDC providers and roles letting GKE workloads manage records in the public Route53 zone, the GCP OpenBao node use the AWS seal key, and Storage Transfer mirror the snapshot bucket. Owned by neither cloud"`.

- [ ] **Step 4: Validate**

```bash
tofu fmt -recursive opentofu/shared/aws-gcp-federation
(cd opentofu/shared/aws-gcp-federation && tofu init -backend=false >/dev/null && tofu validate)
(cd opentofu/shared/aws-gcp-federation && trivy config --exit-code=1 .)
```

Expected: valid, trivy exit 0.

- [ ] **Step 5: Commit**

```bash
git add opentofu/shared/aws-gcp-federation
git commit -m "feat(federation): AWS trusts Google-signed identities for the OpenBao standby seal and the snapshot mirror

A second OIDC provider (accounts.google.com) and two roles pinned by
subject: openbao-standby-seal grants the GCP OpenBao node the multi-region
seal key by alias, openbao-snapshot-mirror grants Google's Storage Transfer
service agent read on the snapshot bucket. Both are created only once their
GCP subject IDs are known, so an AWS-only apply is unaffected."
```

---

### Task 10: GCP OpenBao cluster stack — identity from the lineage, Raft, `seal_provider`, AWS token timer, pre-destroy snapshot

**Files:**
- Create: `opentofu/gcp/openbao/cluster/lineage.tf`
- Modify: `opentofu/gcp/openbao/cluster/iam.tf`
- Modify: `opentofu/gcp/openbao/cluster/compute.tf:73-76,96-110`
- Modify: `opentofu/gcp/openbao/cluster/variables.tf`
- Modify: `opentofu/gcp/openbao/cluster/scripts/startup-script.sh:141-151` and its tail
- Modify: `opentofu/gcp/openbao/cluster/firewall.tf` and
  `opentofu/gcp/openbao/cluster/outputs.tf` — four more references to the
  service account Step 1 deletes: three `target_service_accounts` entries in the
  firewall rules and the `service_account_email` output. Same substitution to
  `local.lineage.openbao_node_sa_email`. `tofu validate` fails until all four
  are done, so they are part of Step 1 rather than an implementer's improvisation.
- Modify: `opentofu/gcp/openbao/cluster/stack.tm.hcl`
- Modify: `opentofu/gcp/openbao/cluster/workflows.tm.hcl` (`destroy`)
- Modify: `opentofu/gcp/openbao/cluster/compute.tf:1-9` header comment

- [ ] **Step 1: The node identity comes from the lineage**

Create `lineage.tf`:

```hcl
# The GCP lineage owns the node's service account (stable unique ID, trusted by
# the AWS seal role) and the snapshot bucket. This stack reads both.
data "terraform_remote_state" "lineage" {
  backend = "gcs"

  config = {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/openbao/lineage"
  }
}

locals {
  lineage = data.terraform_remote_state.lineage.outputs
}
```

In `iam.tf`, delete the `resource "google_service_account" "openbao"` block and replace every `google_service_account.openbao.email` with `local.lineage.openbao_node_sa_email` (three occurrences: two KMS members, one Secret Manager member). Replace the paragraph starting `# Unseal. Not admin on the key.` with:

```hcl
# Unseal with the GCP key, in gcpckms mode. In awskms mode (a standby restoring
# an AWS snapshot) these grants are unused and harmless -- the seal then talks
# to AWS KMS through the federated role in var.aws_seal_role_arn. The service
# account itself is the lineage's (lineage.tf): its unique ID is what the AWS
# side trusts, so it must not be recreated with this stack.
```

In `compute.tf`, replace `email = google_service_account.openbao.email` with `email = local.lineage.openbao_node_sa_email`.

- [ ] **Step 2: Variables for the seal choice**

Append to `variables.tf`:

```hcl
# --- Seal --------------------------------------------------------------------
#
# gcpckms is GCP-only mode: this cloud's own OpenBao, its own hand-created key.
# awskms is the STANDBY role: this node restores a snapshot taken by the AWS
# active instance, and raft data is barrier-encrypted under the seal that
# wrapped it, so the standby has to use the SAME AWS key -- reached through the
# federated role, with a Compute Engine identity token refreshed by a systemd
# timer (scripts/startup-script.sh). Design scenario A: survives an AWS regional
# outage (the key is multi-region), not the loss of the AWS account.
variable "seal_provider" {
  description = "gcpckms (own key, GCP-only mode) or awskms (standby for the AWS lineage). See the cross-cloud failover guide"
  type        = string
  default     = "gcpckms"

  validation {
    condition     = contains(["gcpckms", "awskms"], var.seal_provider)
    error_message = "seal_provider must be gcpckms or awskms."
  }
}

variable "aws_seal_kms_key_id" {
  description = "awskms only: the multi-region key ID (mrk-...) from opentofu/aws/openbao/lineage output seal_key_id"
  type        = string
  default     = ""
}

variable "aws_seal_region" {
  description = "awskms only: region of the seal key copy to use. The REPLICA region, so a eu-west-3 outage does not matter"
  type        = string
  default     = "eu-west-1"
}

variable "aws_seal_role_arn" {
  description = "awskms only: opentofu/shared/aws-gcp-federation output openbao_standby_seal_role_arn"
  type        = string
  default     = ""
}
```

In `compute.tf`, extend the `templatefile(... startup-script.sh ...)` map with:

```hcl
      seal_provider           = var.seal_provider
      aws_seal_kms_key_id     = var.aws_seal_kms_key_id
      aws_seal_region         = var.aws_seal_region
      aws_seal_role_arn       = var.aws_seal_role_arn
```

Add a precondition on the instance template so `awskms` without its inputs fails at plan:

```hcl
  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.seal_provider == "gcpckms" || (var.aws_seal_kms_key_id != "" && var.aws_seal_role_arn != "")
      error_message = "seal_provider = awskms needs aws_seal_kms_key_id and aws_seal_role_arn."
    }
  }
```

(replacing the existing `lifecycle { create_before_destroy = true }` block).

- [ ] **Step 3: Raft, and the seal branch, in the boot script**

In `scripts/startup-script.sh`, replace:

```bash
storage "file" {
  path = "${openbao_data_path}"
}

seal "gcpckms" {
  project    = "${project_id}"
  region     = "${region}"
  key_ring   = "${kms_key_ring}"
  crypto_key = "${kms_crypto_key}"
}
EOF
```

with:

```bash
# REQUIRED with Integrated Storage, and it was missing here while the backend
# was `file`. With mlock enabled OpenBao locks the whole Bolt database into
# physical memory and the OOM killer takes the process once it outgrows RAM
# (https://openbao.org/docs/rfcs/mlock-removal/). Harmless under `file`; on this
# 2 GB e2-small now running raft it is the documented OOM path, and the
# retry-forever drop-in below would turn it into a slow crashloop rather than a
# clean failure. The AWS sibling and the CI drill both set it.
disable_mlock = true

# Raft, single node. `file` could neither take nor receive a snapshot, so a
# node's contents died with it; a one-node raft cluster is bootstrapped by
# `operator init` and costs nothing extra. No `retry_join` at all, unlike AWS:
# there is no second node to find, so `operator init` bootstraps the single
# voter and it is leader immediately. api_addr is the FQDN so a restored
# snapshot's peer list (which raft.Restore discards anyway) never has to match.
storage "raft" {
  path    = "${openbao_data_path}"
  node_id = "$(hostname)"
}

%{ if seal_provider == "awskms" }
# STANDBY seal: the AWS lineage's multi-region key, in its replica region,
# reached with the federated role. Credentials come from the SDK's web-identity
# provider -- AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE in the systemd
# drop-in below -- so nothing is in this file.
seal "awskms" {
  region     = "${aws_seal_region}"
  kms_key_id = "${aws_seal_kms_key_id}"
}
%{ else }
seal "gcpckms" {
  project    = "${project_id}"
  region     = "${region}"
  key_ring   = "${kms_key_ring}"
  crypto_key = "${kms_crypto_key}"
}
%{ endif }
EOF
```

Then, **before** the line `systemctl daemon-reload` near the end of the file, insert:

```bash
%{ if seal_provider == "awskms" }
# AWS web-identity token for the awskms seal.
# ------------------------------------------
# A Compute Engine identity token (aud = sts.amazonaws.com, sub = this service
# account's unique ID) is written where the AWS SDK's web-identity credential
# provider reads it, and refreshed every 50 minutes -- the token lives one hour.
# The seal only needs it at unseal and at key operations, so a stopped timer
# does not stop a running node; it stops the NEXT unseal. `bao status` and the
# OpenBaoSealed alert are what surface that.
install -d -m 0750 -o root -g openbao /run/openbao

cat << 'EOF' > /usr/local/bin/openbao-aws-token.sh
#!/bin/bash
set -euo pipefail
TOKEN=$(curl -fsS -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=sts.amazonaws.com&format=full")
umask 027
printf '%s' "$TOKEN" > /run/openbao/aws-web-identity-token.tmp
chown root:openbao /run/openbao/aws-web-identity-token.tmp
mv -f /run/openbao/aws-web-identity-token.tmp /run/openbao/aws-web-identity-token
EOF
chmod 0755 /usr/local/bin/openbao-aws-token.sh

cat << 'EOF' > /etc/systemd/system/openbao-aws-token.service
[Unit]
Description=Refresh the AWS web-identity token the OpenBao awskms seal uses

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openbao-aws-token.sh
EOF

cat << 'EOF' > /etc/systemd/system/openbao-aws-token.timer
[Unit]
Description=Refresh the OpenBao AWS web-identity token every 50 minutes

[Timer]
OnBootSec=0
OnUnitActiveSec=50min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

# The seal reads these at start. A drop-in rather than /etc/openbao/openbao.env
# so it does not depend on the packaged unit's EnvironmentFile handling.
cat << EOF > /etc/systemd/system/openbao.service.d/aws-seal.conf
[Unit]
After=openbao-aws-token.service
Requires=openbao-aws-token.service

[Service]
Environment=AWS_ROLE_ARN=${aws_seal_role_arn}
Environment=AWS_WEB_IDENTITY_TOKEN_FILE=/run/openbao/aws-web-identity-token
Environment=AWS_REGION=${aws_seal_region}
EOF

systemctl daemon-reload
systemctl enable --now openbao-aws-token.timer
%{ endif }
```

(The `openbao.service.d` directory is created by the existing `restart.conf` block above it; keep that block first.)

Replace the file's header comment sentence `This mirrors the AWS stack's "dev" mode, not "ha"` … `not attempted here.` in `compute.tf` with:

```hcl
# Single node on raft, like the AWS stack's "dev" mode. The node's storage is
# derived state: the lineage's newest snapshot is restored into it on every
# deploy (opentofu/gcp/openbao/management/workflows.tm.hcl, rehydrate), so a
# recreated instance is a restore, not a loss. Multi-node raft remains future
# work.
```

- [ ] **Step 4: Ordering and the pre-destroy snapshot**

In `stack.tm.hcl`, replace:

```hcl
  after = [
    "/opentofu/gcp/network"
  ]
```

with:

```hcl
  after = [
    "/opentofu/gcp/network",
    "/opentofu/gcp/openbao/lineage",
  ]
```

In `workflows.tm.hcl`, in `script "destroy"`, insert immediately after the `terramate-destroy-confirm.sh` line:

```bash
        # One last snapshot into the lineage bucket before the node goes -- the
        # in-cluster CronJob is already gone at this point of a reverse destroy.
        # Fails hard when OpenBao is unreachable; TM_OPENBAO_SKIP_SNAPSHOT=true
        # is the override for a node that is already dead.
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --cloud gcp --project ogenki-435905 \
          --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file .tls/ca.pem
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" pre-destroy-snapshot \
          --cloud gcp --project ogenki-435905 \
          --url https://bao.priv.gcp.ogenki.io:8200 \
          --root-token-secret-name openbao-priv-gcp-root-token \
          --snapshot-bucket ogenki-435905-ogenki-openbao-snapshot \
          --ca-file .tls/ca.pem
```

- [ ] **Step 5: Validate**

```bash
tofu fmt -recursive opentofu/gcp/openbao/cluster
(cd opentofu/gcp/openbao/cluster && tofu init -backend=false >/dev/null && tofu validate)
(cd opentofu/gcp/openbao/cluster && trivy config --exit-code=1 --config trivy.yaml .)
```

Expected: valid, trivy exit 0.

- [ ] **Step 6: Commit**

```bash
git add opentofu/gcp/openbao/cluster
git commit -m "feat(openbao): GCP cluster runs raft, takes its identity from the lineage, can seal with the AWS key

seal_provider selects gcpckms (GCP-only mode) or awskms (standby for the
AWS lineage): the latter reaches the multi-region key in its replica region
with a Compute Engine identity token a systemd timer refreshes into the
SDK's web-identity file. storage moves from file to single-node raft so the
node can be rehydrated. destroy snapshots to the lineage bucket first."
```

---

### Task 11: GCP management and `gke/configure` — rehydrate, destroy gate, `lineage/` mount, AppRole removed, `jwt/gcp-0`

**Files:**
- Modify: `opentofu/gcp/openbao/management/workflows.tm.hcl`
- Modify: `opentofu/gcp/openbao/management/auth.tf`
- Modify: `opentofu/gcp/openbao/management/secrets.tf`
- Modify: `opentofu/gcp/openbao/management/iam.tf`
- Modify: `opentofu/gcp/openbao/management/outputs.tf`
- Modify: `opentofu/gcp/openbao/management/variables.tf`
- Modify: `opentofu/gcp/openbao/management/backend.tf` and
  `opentofu/gcp/openbao/management/policies/cert-manager.hcl.tftpl` — comments only,
  both falsified by Step 2. `backend.tf` justifies this stack's state protection by
  "cert-manager's live AppRole secret_id", which no longer exists; the policy template
  documents cert-manager's runtime calls as `POST auth/approle/login`, which is now
  `auth/jwt/<cluster>/login`, and reasons about "a leaked secret_id" that cannot exist.
  Both would otherwise survive as the only places in the GCP tree still describing
  AppRole as current.
- Modify: `opentofu/gcp/openbao/management/policies/snapshot.hcl`
- Create: `opentofu/gcp/openbao/management/mounts.tf`
- Create: `opentofu/gcp/gke/configure/openbao.tf`
- Modify: `opentofu/gcp/gke/configure/providers.tf`, `versions.tf`, `variables.tf`,
  `data.tf`, `kubernetes.tf`, `workflows.tm.hcl`. **Not** `variables.tfvars`: every new
  variable carries a correct real-value default, so there is nothing to set there.

- [ ] **Step 1: Management workflow — rehydrate replaces init; destroy gated**

In `opentofu/gcp/openbao/management/workflows.tm.hcl`, replace the `openbao_init` global (the heredoc from `openbao_init = <<-EOT` to its `EOT`) with:

```hcl
  # Rehydrate -- or, on a lineage's first deploy, initialise. The CA fetch runs
  # first so the restore verifies the server. See the AWS twin for the full
  # rationale; the only differences are the cloud flag and the GCS bucket.
  openbao_rehydrate = <<-EOT
    bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" rehydrate \
      --url https://bao.priv.gcp.ogenki.io:8200 \
      --cloud gcp \
      --project ogenki-435905 \
      --root-token-secret-name openbao-priv-gcp-root-token \
      --recovery-keys-secret-name openbao-priv-gcp-recovery-keys \
      --snapshot-bucket ogenki-435905-ogenki-openbao-snapshot \
      --ca-file .tls/ca.pem
  EOT
```

and rewrite the leading comment of that `globals` block to describe rehydrate instead of init (drop the paragraph about the missing init step). In `script "deploy"`, swap the two lines so the CA fetch precedes rehydrate:

```bash
        ${global.openbao_ca_fetch}
        ${global.openbao_rehydrate}
```

Replace the whole `script "destroy"` with:

```hcl
# Gated like the AWS management stack and the lineage stacks: the PKI mount,
# auth mounts, policies and the lineage/ marker mount are lineage state carried
# by the raft snapshot. Destroying them here would empty the snapshot the
# cluster stack takes next. The former tolerant destroy and its Secret Manager
# sweep are gone with the AppRole credential they existed for.
script "destroy" {
  name        = "GCP OpenBao Management Destroy (guarded, opt-in)"
  description = "Requires TM_LINEAGE_DESTROY=true: this stack's resources are lineage state"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        if [ "$${TM_LINEAGE_DESTROY:-}" != "true" ]; then
          echo "[skip] opentofu/gcp/openbao/management destroy: the PKI mount, auth mounts and"
          echo "       policies here are lineage state carried by the raft snapshot. Set"
          echo "       TM_LINEAGE_DESTROY=true to destroy the lineage on purpose."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
        ${global.openbao_ca_fetch}
        ${global.provisioner} destroy -parallelism=1 -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}
```

- [ ] **Step 2: Management resources — AppRole out, `lineage/` in**

`auth.tf`: delete the whole file's contents and replace with:

```hcl
# Machine authentication is the JWT method, one mount per cluster, created by
# that cluster's configure stack (opentofu/gcp/gke/configure/openbao.tf) --
# see opentofu/aws/openbao/management/auth.tf for why. The policies those roles
# reference are in policies.tf. The AppRole backend that lived here, with its
# pinned cert-manager role_id and the two Secret Manager entries, is gone: a
# JWT login mints nothing long-lived.
#
# No human auth method on GCP yet; operators use the root token from
# openbao-priv-gcp-root-token, as documented.
```

`secrets.tf`: delete the file's contents and replace with:

```hcl
# Nothing here any more. cert-manager's and the snapshot job's AppRole
# credentials, which this file wrote to Secret Manager, are replaced by the JWT
# method (see auth.tf). The bucket name the snapshot job needs is a per-cluster
# Flux variable (openbao_snapshot_bucket in opentofu/gcp/gke/configure).
```

`iam.tf`: delete `google_secret_manager_secret_iam_member.external_secrets_approle` and `google_secret_manager_secret_iam_member.external_secrets_snapshot`; keep `external_secrets_ca_chain` and the `locals`/`data.google_project`. Update the header comment's first paragraph to say "External Secrets' access to the ONE secret it still reads: the CA chain."

`outputs.tf`: delete the `approle_secret_name` output.

`variables.tf`: delete `approle_secret_name`, `snapshot_approle_secret_name`, `snapshot_bucket_name`.

`locals.tf`: delete `approle_bound_cidrs` (and its comment); keep `openbao_address` and `network`. If `network` is then unused, delete it and the `data.terraform_remote_state.network` block in `data.tf` too.

Create `mounts.tf`:

```hcl
# Root-namespace kv-v2 mount for lineage bookkeeping -- the snapshot freshness
# marker `check_timestamp`, written by the snapshot job before every snapshot
# and read by a restore. Same mount, same path as AWS, so one script serves
# both clouds.
resource "vault_mount" "lineage" {
  path        = "lineage"
  type        = "kv-v2"
  description = "Lineage bookkeeping: the snapshot freshness marker"
}
```

`policies/snapshot.hcl`: replace its contents with the AWS file's new contents from Task 5 Step 5 (identical).

`roles.tf`: replace `allowed_domains  = [var.private_domain_name]` with:

```hcl
  # Both private domains, like AWS: when this OpenBao is the restored STANDBY of
  # the AWS lineage it issues for aws-0 too. (Irrelevant on a rehydrated node --
  # the role comes back inside the snapshot -- but a fresh GCP-only lineage must
  # start with the same shape.)
  allowed_domains  = [var.private_domain_name, "priv.aws.ogenki.io"]
```

and replace the comment above the resource (`Scoped to this cloud's private domain only ...`) accordingly.

- [ ] **Step 3: `gke/configure` — vault provider, mount, roles, variables**

`versions.tf`: add `vault = { source = "hashicorp/vault", version = "~> 5.0" }` to `required_providers`.

`providers.tf`: append

```hcl

# OpenBao, for this cluster's JWT auth mount (openbao.tf). Root token from
# Secret Manager, CA chain written to .tls/ by the deploy workflow first.
provider "vault" {
  address      = "https://bao.${local.init.private_domain_name}:8200"
  token        = jsondecode(data.google_secret_manager_secret_version.openbao_root_token.secret_data)["token"]
  ca_cert_file = var.openbao_ca_cert_file
}
```

`data.tf`: append

```hcl

# The GCP lineage's root token, for the vault provider.
data "google_secret_manager_secret_version" "openbao_root_token" {
  secret  = var.openbao_root_token_secret_name
  project = var.project_id
}
```

`variables.tf`: append

```hcl
variable "openbao_root_token_secret_name" {
  description = "GCP Secret Manager entry holding the OpenBao root token ({\"token\": ...}), for the vault provider that creates this cluster's JWT auth mount"
  type        = string
  default     = "openbao-priv-gcp-root-token"
}

variable "openbao_ca_cert_file" {
  description = "CA chain used to verify OpenBao's certificate. Written by `openbao-config.sh ca --cloud gcp` in the deploy workflow; .tls/ is gitignored."
  type        = string
  default     = ".tls/ca.pem"
}

variable "openbao_jwt_audience" {
  description = "Audience every ServiceAccount token presented to OpenBao must carry"
  type        = string
  default     = "openbao"
}

# Which OpenBao this cluster's pods reach through the neutral `openbao` Service.
# Only consumed by security/base/openbao-endpoint/remote, i.e. when this cluster
# consumes the AWS active instance. In GCP-only mode the overlay lists the
# local form and this value is unused. One of `tofu output nlb_private_ips` in
# opentofu/aws/openbao/cluster.
variable "openbao_target_ip" {
  description = "Fixed private address of the active OpenBao's NLB, for the remote form of the openbao Service. Unused in GCP-only mode."
  type        = string
  default     = "10.0.15.250"
}
```

Create `openbao.tf`:

```hcl
# This cluster's JWT auth mount on the OpenBao its Service points at. Same
# shape as opentofu/aws/eks/configure/openbao.tf -- read the rationale there.
# GKE's issuer is deterministic from project/zone/name, so this COULD live in
# the management stack; it lives here for symmetry, so "where is a cluster's
# auth mount created" has one answer.
resource "vault_jwt_auth_backend" "cluster" {
  path               = "jwt/${var.cluster_name}"
  type               = "jwt"
  description        = "Kubernetes ServiceAccount tokens from cluster ${var.cluster_name}"
  oidc_discovery_url = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${local.init.cluster_location}/clusters/${var.cluster_name}"
  bound_issuer       = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${local.init.cluster_location}/clusters/${var.cluster_name}"

  # No mount `tune` -- see the note in opentofu/aws/eks/configure/openbao.tf:
  # in provider v5 it is a list(object) attribute with eight non-optional
  # fields, so block syntax is invalid and a partial object is rejected. The
  # roles below bound TTL and token type instead.
}

locals {
  openbao_roles = {
    cert-manager = {
      service_account = "cert-manager"
      namespace       = "security"
      policies        = ["cert-manager"]
    }
    external-secrets = {
      service_account = "external-secrets"
      namespace       = "security"
      policies        = ["default"]
    }
    openbao-snapshot = {
      service_account = "openbao-snapshot"
      namespace       = "security"
      policies        = ["snapshot"]
    }
  }
}

resource "vault_jwt_auth_backend_role" "cluster" {
  for_each = local.openbao_roles

  backend         = vault_jwt_auth_backend.cluster.path
  role_name       = each.key
  role_type       = "jwt"
  bound_audiences = [var.openbao_jwt_audience]
  bound_subject   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  user_claim      = "sub"
  token_policies  = each.value.policies
  token_ttl       = 600
  token_max_ttl   = 1200
  token_type      = "default-service"
}
```

`kubernetes.tf`: in the ConfigMap `data`, replace the `openbao_snapshot_secret` line (its value is the flat name `openbao-priv-gcp-snapshot`) and the comment paragraph above it (from `# Secret Manager keys for the two ExternalSecrets` to `# snapshot_approle_secret_name.`) with:

```hcl
      # The lineage's snapshot bucket (opentofu/gcp/openbao/lineage), consumed
      # by security/base/openbao-snapshot/snapshot-cronjob.yaml as BUCKET_NAME.
      # Project-prefixed here, region-prefixed on AWS.
      openbao_snapshot_bucket = "${var.project_id}-ogenki-openbao-snapshot"
      # security/base/openbao-endpoint/remote, when this cluster consumes the AWS
      # active OpenBao. Unused in GCP-only mode.
      openbao_target_ip = var.openbao_target_ip
      # Secret Manager key for apps/base/ai/llm/hf-token-externalsecret.yaml.
      # FLAT and dash-separated (GCP forbids "/") -- ADR-0023. Hand-created,
      # only needed when the LLM platform is enabled on this cluster.
```

(keep the following `llm_hf_token_secret` line, whose value is the flat name `llm-platform-hf-token`.)

`workflows.tm.hcl`: in both `deploy` and `preview`, insert before `${global.provisioner} init`:

```bash
        # The vault provider (openbao.tf) needs the CA chain on disk before init.
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --cloud gcp --project ogenki-435905 \
          --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file .tls/ca.pem
```

and in `destroy`, insert the same three lines before the `destroy-stage2.sh` call.

- [ ] **Step 4: Validate**

```bash
tofu fmt -recursive opentofu/gcp
for s in opentofu/gcp/openbao/management opentofu/gcp/gke/configure; do (cd $s && tofu init -backend=false >/dev/null && tofu validate) || exit 1; done
(cd opentofu/gcp/openbao/management && trivy config --exit-code=1 --config trivy.yaml .)
python3 scripts/flux-schema/check-substitution.py
grep -rn "approle" opentofu/gcp/ --include='*.tf' --include='*.hcl'; echo "grep-exit=$?"
```

Expected: both valid; trivy exit 0; check-substitution exit 0 (gcp-0 now defines `openbao_snapshot_bucket` and `openbao_target_ip`); the grep prints only the explanatory comments written in this task, `grep-exit=0`.

- [ ] **Step 5: Commit**

```bash
git add opentofu/gcp/openbao/management opentofu/gcp/gke/configure
git commit -m "feat(gcp): OpenBao management rehydrates and is destroy-gated; gke/configure owns jwt/gcp-0

Mirror of the AWS change: deploy fetches the CA then rehydrates from the
GCS bucket (plain init on a first deploy), destroy needs
TM_LINEAGE_DESTROY, a lineage/ marker mount is added, the AppRole backend
and both Secret Manager credential entries go. gke/configure gains the
vault provider, the jwt/gcp-0 mount with three roles, and the
openbao_snapshot_bucket / openbao_target_ip variables."
```

---

### Task 12: The weekly restore drill (GitHub Actions)

**Files:**
- Create: `.github/workflows/openbao-restore-drill.yml`

**Deviation from the design, stated:** the design had the drill assert `check_timestamp`. Reading it needs a token, and the only way CI could get one is the recovery keys, which must not sit in a CI runner's reach. The drill therefore asserts what the **unauthenticated** endpoints prove: the node initialised, unsealed with the lineage seal, and restored a snapshot whose PKI mount answers with a certificate chaining to the offline root. `check_timestamp` stays asserted by the operator-run rehydrate. The GCS mirror check compares the newest object name and size on both sides.

Repository variables to create (Settings → Secrets and variables → Actions → Variables) from the Task 15/16 outputs: `AWS_DRILL_ROLE_ARN`, `GCP_DRILL_WIF_PROVIDER`, `GCP_DRILL_SERVICE_ACCOUNT`. The offline root certificate is public material; it is committed as `.github/openbao-root-ca.pem` in Task 14 so the drill can verify the chain without any cloud read.

- [ ] **Step 1: The workflow**

```yaml
name: OpenBao restore drill

# Proves, every week, that the newest snapshot in the lineage bucket can be
# restored by a node that has nothing but the lineage seal key -- and that the
# GCS mirror holds the same newest object. This is the "restore is not a
# hypothesis" requirement of the store-of-record design.
#
# What it deliberately does NOT have: the recovery keys. Everything asserted
# below comes from unauthenticated endpoints (sys/health, the PKI mount's CA
# endpoint), so a compromised runner can restore a snapshot it cannot read.

on:
  schedule:
    - cron: "0 6 * * 1" # Mondays 06:00 UTC, after the 04:00 snapshot and 05:00 mirror
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

env:
  # renovate: datasource=github-releases depName=openbao/openbao
  BAO_VERSION: 2.6.2
  AWS_REGION: eu-west-3
  SNAPSHOT_BUCKET: eu-west-3-ogenki-openbao-snapshot
  MIRROR_BUCKET: ogenki-435905-ogenki-openbao-snapshot
  SEAL_KEY_ALIAS: alias/openbao-seal

jobs:
  drill:
    name: Restore the newest snapshot into a throwaway node
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: ${{ vars.AWS_DRILL_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Authenticate to GCP (Workload Identity Federation)
        uses: google-github-actions/auth@v3
        with:
          workload_identity_provider: ${{ vars.GCP_DRILL_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_DRILL_SERVICE_ACCOUNT }}

      - name: Install gcloud
        uses: google-github-actions/setup-gcloud@v3

      - name: Install bao (checksum-verified)
        run: |
          set -euo pipefail
          tarball="openbao_${BAO_VERSION}_linux_amd64.tar.gz"
          base="https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}"
          curl -fsSL "${base}/${tarball}" -o "/tmp/${tarball}"
          curl -fsSL "${base}/checksums.txt" -o /tmp/checksums.txt
          grep -E "  ${tarball}$" /tmp/checksums.txt > /tmp/bao.sha256sum
          (cd /tmp && sha256sum -c bao.sha256sum)
          tar -xzf "/tmp/${tarball}" -C /tmp bao
          sudo install -m 0755 /tmp/bao /usr/local/bin/bao
          bao version

      - name: Fetch the newest snapshot
        id: snapshot
        run: |
          set -euo pipefail
          key=$(aws s3api list-objects-v2 --bucket "$SNAPSHOT_BUCKET" \
            --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
          if [ -z "$key" ] || [ "$key" = "None" ]; then
            echo "::error::no snapshot in s3://$SNAPSHOT_BUCKET"; exit 1
          fi
          size=$(aws s3api head-object --bucket "$SNAPSHOT_BUCKET" --key "$key" --query ContentLength --output text)
          aws s3 cp "s3://$SNAPSHOT_BUCKET/$key" "$RUNNER_TEMP/bao.snap"
          echo "key=$key" >> "$GITHUB_OUTPUT"
          echo "size=$size" >> "$GITHUB_OUTPUT"
          echo "newest S3 object: $key ($size bytes)"

      - name: Start a throwaway OpenBao sealed by the lineage key
        run: |
          set -euo pipefail
          mkdir -p "$RUNNER_TEMP/raft"
          cat > "$RUNNER_TEMP/bao.hcl" <<EOF
          ui            = false
          disable_mlock = true
          api_addr      = "http://127.0.0.1:8200"
          cluster_addr  = "https://127.0.0.1:8201"
          listener "tcp" {
            address     = "127.0.0.1:8200"
            tls_disable = true
          }
          storage "raft" {
            path    = "$RUNNER_TEMP/raft"
            node_id = "drill"
          }
          seal "awskms" {
            region     = "$AWS_REGION"
            kms_key_id = "$SEAL_KEY_ALIAS"
          }
          EOF
          nohup bao server -config="$RUNNER_TEMP/bao.hcl" > "$RUNNER_TEMP/bao.log" 2>&1 &
          for _ in $(seq 1 30); do
            code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8200/v1/sys/health || true)
            [ "$code" = "501" ] && break
            sleep 1
          done
          [ "$code" = "501" ] || { echo "::error::server did not come up (last health code: $code)"; cat "$RUNNER_TEMP/bao.log"; exit 1; }

      - name: Initialise with throwaway shares and restore
        env:
          VAULT_ADDR: http://127.0.0.1:8200
        run: |
          set -euo pipefail
          # The throwaway root token is only used to POST the snapshot; the
          # restored token store does not contain it, and nothing later needs
          # a token.
          VAULT_TOKEN=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json | jq -r .root_token)
          export VAULT_TOKEN
          bao status
          bao operator raft snapshot restore -force "$RUNNER_TEMP/bao.snap"
          unset VAULT_TOKEN
          # After a restore the node reloads and unseals with the lineage key.
          for _ in $(seq 1 30); do
            code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8200/v1/sys/health || true)
            [ "$code" = "200" ] && break
            sleep 1
          done
          if [ "$code" != "200" ]; then
            echo "::error::node is not unsealed+active after restore (health code $code) -- the seal key cannot unwrap this snapshot"
            tail -50 "$RUNNER_TEMP/bao.log"; exit 1
          fi
          bao status

      - name: Assert the PKI issuer came back and chains to the offline root
        run: |
          set -euo pipefail
          curl -fsS http://127.0.0.1:8200/v1/pki_private_issuer/ca_chain > "$RUNNER_TEMP/chain.pem"
          openssl x509 -in "$RUNNER_TEMP/chain.pem" -noout -subject -issuer -enddate
          # Split the chain and verify the leaf-most CA against the committed root.
          awk 'BEGIN{n=0} /BEGIN CERT/{n++} {print > sprintf("'"$RUNNER_TEMP"'/c%d.pem", n)}' "$RUNNER_TEMP/chain.pem"
          openssl verify -CAfile .github/openbao-root-ca.pem -untrusted "$RUNNER_TEMP/chain.pem" "$RUNNER_TEMP/c1.pem"

      - name: Assert the GCS mirror holds the same newest object
        run: |
          set -euo pipefail
          key="${{ steps.snapshot.outputs.key }}"
          size="${{ steps.snapshot.outputs.size }}"
          gsize=$(gcloud storage objects describe "gs://$MIRROR_BUCKET/$key" --format='value(size)' 2>/dev/null || echo missing)
          if [ "$gsize" = "missing" ]; then
            echo "::error::gs://$MIRROR_BUCKET/$key is absent -- the Storage Transfer mirror is behind or broken"; exit 1
          fi
          if [ "$gsize" != "$size" ]; then
            echo "::error::size mismatch for $key: s3=$size gcs=$gsize"; exit 1
          fi
          echo "mirror OK: $key ($gsize bytes) present on both sides"

      - name: Stop the node
        if: always()
        run: pkill -f 'bao server' || true
```

- [ ] **Step 2: Lint**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/openbao-restore-drill.yml')); print('yaml ok')"`
Expected: `yaml ok`. If `actionlint` is available (`mise x -- actionlint` or `brew install actionlint`), run `actionlint .github/workflows/openbao-restore-drill.yml` and expect no output.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/openbao-restore-drill.yml
git commit -m "ci(openbao): weekly restore drill

A throwaway node sealed by the lineage key restores the newest S3 snapshot
and must come up unsealed with a PKI issuer that chains to the committed
offline root; the GCS mirror must hold the same newest object. No recovery
keys reach CI: every assertion is an unauthenticated endpoint."
```

---

### Task 13: Records and documentation

**Files:**
- Create: `website/content/docs/decisions/0032-openbao-store-of-record-lineage.md`
- Modify: `website/content/docs/decisions/_index.md` (table row)
- Modify: `website/content/docs/decisions/0025-cloud-managed-secret-stores.md` (amendment callout)
- Modify: `website/content/docs/decisions/0027-primary-cloud-provider.md` (table row, one paragraph)
- Create: `website/content/docs/guides/openbao-cross-cloud-failover.md`
- Modify: `website/content/docs/platform/security/openbao.md`
- Modify: `website/content/docs/platform/security/pki-and-secrets.md`
- Modify: `website/content/docs/get-started/costs.md`
- Modify: `website/content/docs/platform/foundations/aws.md`, `website/content/docs/platform/foundations/gcp.md`
- Modify: `website/content/docs/platform/networking/private-access.md`
- Modify: `.doc-claims.yaml`
- Modify: `CLAUDE.md`
- Modify: `docs/gcp-bootstrap.md`
- Modify: three comments that Tasks 6 and 7 falsified and correctly left alone as
  out of scope. Each now describes a removed mechanism in the present tense:
  `clusters/gcp-0/security/security-openbao.yaml` says the AWS copy substitutes
  `${cert_manager_approle_id}` "out of the very Secret its own ExternalSecret
  creates" — aws-0 no longer does that; `scripts/flux-schema/check-substitution.py`'s
  docstring says "one such case exists" of a Secret-sourced variable — after this
  branch there are none, so say so rather than leaving a reader hunting;
  `scripts/flux-schema/render-bundle.py`'s comment above `llm_hf_token_secret`
  cross-references `openbao_snapshot_secret`, a key this branch renamed.
- Modify: `opentofu/aws/openbao/management/README.md` — it documents the AppRole
  machine-auth flow Task 5 deleted, and the old PKI design in which the root CA
  private key was imported into the live mount. Both are now false. Replace the
  AppRole section with a pointer to the per-cluster JWT mounts, and the PKI
  paragraph with the pre-signed-intermediate shape, matching the OpenBao page.
  Task 5 deliberately left this file alone as out of its scope; it lands here.

Write in the site's existing voice (short paragraphs, tables, `{{< callout >}}` shortcodes). Every relative link must resolve (`validate-links.sh`); every claim entry must match (`validate-doc-claims.sh`).

- [ ] **Step 1: ADR-0032**

Create `website/content/docs/decisions/0032-openbao-store-of-record-lineage.md`:

```markdown
---
title: OpenBao is the store of record, durable as a snapshot lineage, active on the primary cloud with restore-based fallback
linkTitle: 0032 · OpenBao lineage
weight: 320
description: OpenBao's storage becomes derived state rebuilt from its newest Raft snapshot on every boot; what persists is a lineage — one multi-region KMS seal key, four bootstrap secrets, a snapshot bucket. One instance is active on AWS and serves both clusters; a GCP standby restores the mirrored snapshot under the same AWS seal. Chosen over per-cloud authoritative instances, an instance with no fallback, a Shamir-sealed standby, the clouds' managed CAs and cert-manager's CA issuer.
lastVerified: 2026-09-02
---

**Status**: Accepted
**Date**: 2026-09-02
**Deciders**: Smana (Platform Owner)
**Related Design**: `docs/superpowers/specs/2026-09-02-openbao-store-of-record-design.md` (repository path; designs are not published)
**Related**: [ADR-0025](0025-cloud-managed-secret-stores.md) — the cost record this
changes the mechanism of; [ADR-0027](0027-primary-cloud-provider.md) — the class
OpenBao moves into; [ADR-0011](0011-openbao-over-vault.md) — the engine

---

## Context

[ADR-0025](0025-cloud-managed-secret-stores.md) made the cloud's managed secret
store the store of record because it is always-on and outlives the platform,
and said OpenBao "remains the target" for a deployment that runs continuously.
Two facts, both verified on 2026-09-02, meant that target could never be
reached by leaving the process on:

- **The seal key was destroyed with the platform.** It lived in the ephemeral
  cluster stack with a 10-day deletion window, so every rebuild minted a new
  key and every earlier snapshot became ciphertext. `dev` mode ran the `file`
  backend and never took one, which is why nothing noticed.
- **The restore procedure was a documented hypothesis.** Nothing had ever
  executed it.

A store of record has to survive the platform. The insight is that *the running
process does not have to be what survives*. Everything a rebuilt OpenBao needs
to come back is small and cheap to keep: a seal key, the material that
bootstraps the node, and the newest snapshot. Call that a **lineage**, keep it
outside every ephemeral stack, and the process becomes derived state — off
between runs in the reference platform, always-on in production, the same
design either way.

## Decision Drivers

- **Cost of the idle floor.** ADR-0025's constraint is real: the reference must
  not pay for an always-on secrets cluster. It may pay ~$1/month for a key.
- **Restorability, proven.** Every deploy of the reference platform and a weekly
  drill must exercise the restore path.
- **One root of trust, offline.** The AWS root private key sat inside the live
  PKI mount; GCP had already fixed that with an offline root.
- **No long-lived credential to reach OpenBao.** Workloads authenticate with
  their cluster's ServiceAccount tokens.
- **A fallback that survives an AWS regional outage**, stated with its limits.
- **GCP-only deployments keep working with no AWS dependency**
  ([ADR-0024](0024-identity-provider-per-cloud.md)).

## Considered Options

### Option 1: Managed stores remain the store of record (status quo)

**Pros**: nothing to build. **Cons**: the platform documents a target it does
not run; the seal-key and restore defects stay; two stores with a placement
rule to learn.

### Option 2: Per-cloud OpenBaos, each authoritative for its cluster

**Pros**: no cross-cloud dependency. **Cons**: a value both clouds need is
seeded twice and drifts (ADR-0025's own negative); two policy models; two roots
of trust or a shared root with two issuing chains and no single audit trail.

### Option 3: One OpenBao, no fallback

**Pros**: simplest. **Cons**: a GCP-only platform cannot authenticate to
anything, which is the dependency ADR-0024 removed for the identity provider.

### Option 4: One active OpenBao on the primary cloud, a snapshot lineage, a standby restoring under the same seal *(chosen)*

**Pros**: one store, one policy model, one root; the floor moves by one key;
restore is exercised on every deploy; fallback survives a regional outage.
**Cons**: the standby depends on AWS KMS (mitigated by a multi-region replica);
a bootstrap tier of four secrets per cloud remains in the managed stores; new
cross-cloud plumbing (Tailscale egress, two federated roles).

### Rejected on the seal: a Shamir-sealed standby

Survives the loss of the AWS account, but every restart becomes a human typing
a key share and Raft auto-join breaks. Seal migration during failover is not an
option either: it requires both seals reachable, which an outage denies.

### Rejected on the PKI: AWS Private CA / GCP CAS, and cert-manager's CA issuer

The clouds' managed CAs cost about $400/month per CA on AWS and are not
portable. cert-manager's built-in CA issuer costs nothing but keeps the
intermediate key in a Kubernetes Secret and removes the self-hosted PKI this
repository exists to demonstrate.

### Rejected earlier: SOPS

ADR-0025, option 3.

## Decision Outcome

**Option 4.** OpenBao is the store of record. Its durable form is the lineage:
`alias/openbao-seal` (multi-region, replica in `eu-west-1`), the snapshot
bucket and its key, and four bootstrap secrets per cloud (server TLS material,
root token, recovery keys, the offline-signed intermediate). The process is
rehydrated from the newest snapshot on every boot; a last snapshot is taken
before every destroy. One instance is active on AWS
([ADR-0027](0027-primary-cloud-provider.md) primary-cloud singleton — OpenBao
changes class from *per-cloud*, with the one property the other singletons lack:
its relocation carries state). Workloads on both clusters authenticate through
the JWT method against their cluster's OIDC issuer. One offline root signs one
intermediate per lineage. A GCP standby restores the GCS mirror sealed by the
same AWS key through OIDC federation; the fallback survives an AWS regional
outage and the loss of AWS compute or Secrets Manager, **not** the loss of the
AWS account — a deliberate trade for keeping auto-unseal.

Staged: Stage 1 builds the lineage, rehydrate, JWT auth, the offline root on
AWS, the mirror, the drill and one executed cross-cloud failover, with the
managed store still the store of record. Stage 2 repoints the
`ClusterSecretStore` and migrates about 36 secrets.

## Consequences

### Positive

- The idle floor moves from about $23 to about $24/month, and the platform runs
  the design it documents.
- Restore stops being a hypothesis: every deploy performs one, and CI drills it
  weekly with no recovery keys in reach.
- No AppRole `SecretID` exists anywhere; the two AppRole entries per cloud are
  gone from the managed stores.
- Tailnet clients trust one root, and no CA private key is on a networked system.

### Negative

- The standby is coupled to AWS KMS. *Mitigation*: multi-region replica; the
  limit is stated in the failover guide.
- Four bootstrap secrets per cloud must exist on both clouds for a fallback to be
  bootstrappable; they are seeded by hand and can drift. *Mitigation*: the list
  is short and `secret-store.sh check` names what is missing.
- New moving parts: a systemd timer refreshing a web-identity token on the GCP
  node, a Storage Transfer job, an egress `ProxyGroup` path, two federated roles.
- A node recreated between snapshots loses writes since the last one (RPO = the
  snapshot cadence: daily in the reference, hourly in production).

### Neutral

- ADR-0025's cost constraint is unchanged; it now bounds whether the process is
  left on between runs, not where the store of record is.
- The `ClusterSecretStore` repoint (Stage 2) is the change ADR-0025 always said
  it would be.

## Implementation Notes

Stage 1 plan: `docs/superpowers/plans/2026-09-02-openbao-store-of-record-stage1.md`.
Lineage stacks: `opentofu/aws/openbao/lineage/`, `opentofu/gcp/openbao/lineage/`.
Rehydrate: `scripts/openbao-config.sh rehydrate`, called by both management
stacks' deploy scripts. Auth mounts: `opentofu/{aws/eks,gcp/gke}/configure/openbao.tf`.
Fallback runbook: [Cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}}).

## References

- [ADR-0025](0025-cloud-managed-secret-stores.md), [ADR-0027](0027-primary-cloud-provider.md), [ADR-0024](0024-identity-provider-per-cloud.md), [ADR-0019](0019-cross-cloud-dns-federation.md)
- [OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}), [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}), [What it costs]({{< relref "/docs/get-started/costs.md" >}})
- OpenBao docs: seal migration requires both seals reachable; Raft nodes must share a seal configuration
```

Add to `website/content/docs/decisions/_index.md`, after the 0031 row:

```markdown
| [0032]({{< relref "/docs/decisions/0032-openbao-store-of-record-lineage.md" >}}) | OpenBao is the store of record, durable as a snapshot lineage, active on the primary cloud with restore-based fallback | Accepted | 2026-09-02 |
```

- [ ] **Step 2: Amend ADR-0025 and ADR-0027**

In `0025-cloud-managed-secret-stores.md`, directly after the `---` that follows the `**Related**` lines, insert:

```markdown
{{< callout type="info" >}}
**Amended 2026-09-02 by [ADR-0032](0032-openbao-store-of-record-lineage.md).**
The constraint recorded below is unchanged: this reference cannot afford an
always-on OpenBao. What changed is what the constraint bounds. OpenBao's storage
is now derived from a *lineage* — a persistent seal key, four bootstrap secrets
and a snapshot bucket — and rehydrated on every boot, so the process can be off
between runs while OpenBao is the store of record. The "Neutral" sentence below
saying OpenBao remains the target is therefore no longer aspirational; the
`ClusterSecretStore` repoint it describes is Stage 2 of ADR-0032's plan. Until
that stage lands, the placement rule in this record still describes the live
platform.
{{< /callout >}}
```

Set its front-matter `lastVerified` to `2026-09-02`.

In `0027-primary-cloud-provider.md`, change the table row

`| **Per-cloud** | every cloud, independently | network, GKE/EKS, OpenBao, secret store, state and backup buckets |`

to

`| **Per-cloud** | every cloud, independently | network, GKE/EKS, secret store, state and backup buckets |`

and the row

`| **Primary-cloud singleton** | the primary cloud | public Route53 zone, ZITADEL, the \`aws-gcp-federation\` OIDC provider and role |`

to

`| **Primary-cloud singleton** | the primary cloud | public Route53 zone, ZITADEL, the \`aws-gcp-federation\` OIDC providers and roles, OpenBao (since [ADR-0032](0032-openbao-store-of-record-lineage.md) — its relocation carries state, by snapshot restore) |`

In its "What it does not change" paragraph, find:

```markdown
Nothing per-cloud. Both clusters keep their own
OpenBao, secret store, state and backups, and neither depends on the other for
them.
```

Replace with:

```markdown
Nothing per-cloud. Both clusters keep their own secret store, state and backups,
and neither depends on the other for them. (OpenBao left this class on
2026-09-02 — [ADR-0032](0032-openbao-store-of-record-lineage.md).)
```

Set `lastVerified: 2026-09-02`.

- [ ] **Step 3: The failover guide**

Create `website/content/docs/guides/openbao-cross-cloud-failover.md`:

```markdown
---
title: OpenBao cross-cloud failover
weight: 60
description: Bring the GCP standby up from the mirrored snapshot under the AWS seal, repoint the surviving cluster, and fail back.
lastVerified: 2026-09-02
---

The active OpenBao runs on AWS and serves both clusters. Its durable form is
the *lineage* ([ADR-0032]({{< relref "/docs/decisions/0032-openbao-store-of-record-lineage.md" >}})):
the multi-region seal key `alias/openbao-seal`, four bootstrap secrets, and the
snapshot bucket `eu-west-3-ogenki-openbao-snapshot`, mirrored daily into
`ogenki-435905-ogenki-openbao-snapshot` by a Storage Transfer job.

## What this survives, and what it does not

| Failure | Covered |
|---|---|
| AWS `eu-west-3` regional outage; AWS compute or Secrets Manager unavailable | yes — the seal key has a replica in `eu-west-1` |
| The AWS account itself lost or closed | **no** — every snapshot is ciphertext under an AWS KMS key. A Shamir seal would cover this at the cost of a human at every restart; the trade is recorded in ADR-0032 |
| Snapshot older than you would like | RPO is the mirror cadence: 24 h as committed, 1 h in the production posture |

Consumers tolerate the gap: External Secrets keeps the last synced Secrets and
cert-manager renews 15 days before expiry. Only *new* secrets and certificates
wait, so this procedure is manual and measured in tens of minutes.

## Preconditions

- The GCP lineage stack has been applied and the federation stack knows its
  identities (`gcp_openbao_standby_sa_unique_id`, `gcp_transfer_agent_subject_id`
  in `opentofu/shared/aws-gcp-federation/variables.tfvars`).
- The four GCP bootstrap secrets exist: `openbao-priv-gcp-server-cert`,
  `openbao-priv-gcp-root-token`, `openbao-priv-gcp-recovery-keys`,
  `openbao-priv-gcp-intermediate-ca`. **For a fallback the root token and
  recovery keys must be the AWS lineage's**, because the restored token store is
  the AWS one: copy them from AWS Secrets Manager into those two GCP entries
  before step 2 (`scripts/secret-store.sh` has no cross-cloud copy; use the two
  CLIs).
- `gcloud auth application-default login` for `ogenki-435905`, a tailnet
  connection, and `TF_VAR_tailscale_api_key`.

## Failover, AWS → GCP

1. **Measure the loss.** The newest mirrored object is the data you will have:

   ```bash
   gcloud storage ls -l gs://ogenki-435905-ogenki-openbao-snapshot/ | sort -k2 | tail -1
   ```

2. **Deploy the standby with the AWS seal.** In
   `opentofu/gcp/openbao/cluster/variables.tfvars` set:

   ```hcl
   seal_provider       = "awskms"
   aws_seal_kms_key_id = "<opentofu/aws/openbao/lineage output seal_key_id>"
   aws_seal_region     = "eu-west-1"
   aws_seal_role_arn   = "<opentofu/shared/aws-gcp-federation output openbao_standby_seal_role_arn>"
   ```

   then, from `opentofu/`:

   ```bash
   TM_CLOUD=gcp terramate script run deploy
   ```

   The management stack's rehydrate step restores from the GCS bucket. Watch
   for `Rehydrated from <object>.` and `PKI issuer present:` in its output.

3. **Verify.**

   ```bash
   export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200 VAULT_CACERT=opentofu/gcp/openbao/management/.tls/ca.pem
   bao status                     # Initialized true, Sealed false, no operator input
   curl -s --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki_private_issuer/ca/pem" | openssl x509 -noout -subject
   ```

   Stop and start the instance (`gcloud compute instances stop/start`) and repeat
   `bao status`: it must come back unsealed on its own.

4. **Repoint the surviving cluster.** For `gcp-0` itself nothing changes: its
   `openbao` Service is the local form. For any other cluster still running,
   switch `security/<cluster>/openbao/kustomization.yaml` to
   `../../base/openbao-endpoint/remote` and set that cluster's `openbao_target_ip`
   to the GCP internal load balancer address (`google_compute_address.openbao`
   in `opentofu/gcp/openbao/cluster`). Commit; Flux reconciles; External Secrets
   and cert-manager pick up the new endpoint on their next interval.

## Failback, GCP → AWS

1. Take a snapshot on the GCP node and mirror it back:

   ```bash
   VAULT_TOKEN=<gcp root token> CLOUD=gcp ./scripts/openbao-snapshot.sh save \
     -a https://bao.priv.gcp.ogenki.io:8200 -b ogenki-435905-ogenki-openbao-snapshot -s /tmp/bao.snap
   gcloud storage cp gs://ogenki-435905-ogenki-openbao-snapshot/<newest>.snap /tmp/back.snap
   aws s3 cp /tmp/back.snap s3://eu-west-3-ogenki-openbao-snapshot/<newest>.snap
   ```

2. Redeploy AWS (`terramate script run deploy` from `opentofu/`); its rehydrate
   restores that object.
3. Restore `seal_provider = "gcpckms"` on the GCP cluster stack and redeploy it,
   or destroy it (`TM_CLOUD=gcp terramate script run --reverse destroy`, which
   snapshots first).
4. Revert the `openbao_target_ip` / overlay changes from step 4 above.

## Drill record

Every executed failover is recorded in
`docs/superpowers/specs/2026-09-02-openbao-store-of-record-verification.md`
(repository path) with the snapshot object, the measured RPO, and the time from
step 2 to step 3.
```

In `website/content/docs/guides/_index.md`, add inside the `{{< cards >}}` block, after the `troubleshooting` card:

```markdown
  {{< card link="openbao-cross-cloud-failover" title="OpenBao cross-cloud failover" subtitle="Bring the GCP standby up from the mirrored snapshot, repoint, and fail back." >}}
```

and set that file's `lastVerified` to `2026-09-02`.

- [ ] **Step 4: OpenBao, PKI & Secrets, costs, foundations, private-access pages**

`openbao.md`:

- Front matter: `description: Namespace layout, the lineage and rehydrate-at-boot, operator login, JWT machine auth, backup and restore, and the 2.6.x concurrency constraint.` and `lastVerified: 2026-09-02`.
- Replace `a single node on \`file\`` / `storage as committed (\`mode = "dev"\`), or five nodes on Raft (3 on-demand + 2` / `spot) with RAID-0 NVMe at \`mode = "ha"\`` with `a single Raft node as committed (\`mode = "dev"\`), or five Raft nodes (3 on-demand + 2 spot) with RAID-0 NVMe at \`mode = "ha"\`` — keep the exact substring `as committed (\`mode = "dev"\`)` because `.doc-claims.yaml` pins it.
- Add a new section after "Namespace layout":

```markdown
## The lineage, and rehydrate at boot

OpenBao's storage is **derived state**. What persists is the *lineage*
([ADR-0032]({{< relref "/docs/decisions/0032-openbao-store-of-record-lineage.md" >}})):

| Component | Where |
|---|---|
| Seal key `alias/openbao-seal`, multi-region (replica in `eu-west-1`) | `opentofu/aws/openbao/lineage/` |
| Snapshot bucket `eu-west-3-ogenki-openbao-snapshot` and its key | same stack (imported from Crossplane) |
| Server TLS material, root token, recovery keys, the offline-signed intermediate | AWS Secrets Manager, hand-seeded |

On every deploy, the management stack's workflow runs
`scripts/openbao-config.sh rehydrate`: a fresh node is initialised with
throwaway shares that are **never stored**, the newest snapshot is restored
into it, and the root token and recovery keys already in Secrets Manager
belong to the restored state. If the bucket is empty — the first deploy of a
lineage — it is a plain init and the new keys are stored. Before the cluster
stack is destroyed, its workflow takes one last snapshot, so nothing written
since the daily CronJob is lost.

The lineage and management stacks are **never destroyed by the default
`destroy`**: their `destroy` scripts no-op unless `TM_LINEAGE_DESTROY=true`.
`gcp-0` has the same shape under `opentofu/gcp/openbao/lineage/` (its seal key
was already a hand-created prerequisite).
```

- Replace the whole "AppRole: machine authentication" section with:

```markdown
## JWT: machine authentication

Workloads authenticate with a **projected ServiceAccount token**, validated by
OpenBao's JWT method against the cluster's public OIDC issuer. Nothing
long-lived is minted or stored. One mount per cluster:

| Mount | Created by | Roles (audience `openbao`) |
|---|---|---|
| `jwt/aws-0` | `opentofu/aws/eks/configure/openbao.tf` | `cert-manager`, `external-secrets`, `openbao-snapshot` |
| `jwt/gcp-0` | `opentofu/gcp/gke/configure/openbao.tf` | same |

The mount lives in the *configure* stack because the EKS issuer URL carries a
per-cluster ID that changes on every rebuild, and the management stack runs
before `eks/init`. The policies the roles bind stay in the management stack.
Each role is bound to one ServiceAccount by full subject
(`system:serviceaccount:security:cert-manager`) and tokens live 10 minutes,
because JWKS validation never consults the API server: a token Kubernetes
revoked stays valid until it expires.

The former AppRole backend, its `snapshot-agent` and `cert-manager` roles and
their Secrets Manager entries are gone. The `app` tenant namespace keeps its
own AppRole as the worked tenancy example.
```

- In "Backup and restore": replace the **Backup** paragraph's `uses the \`snapshot-agent\` AppRole` with `logs in through \`jwt/<cluster>\` as \`openbao-snapshot\``, add after `ship it to S3.`: ` Before the snapshot it writes \`lineage/check_timestamp\`, the marker a restore uses to report the age of what it installed. A Storage Transfer job mirrors the bucket into GCS daily.` Replace the **Restore** paragraph's `checks that \`secret/check_timestamp\` is recent` with `checks \`lineage/check_timestamp\``. Replace the whole "Prerequisites worth stating plainly" list with:

```markdown
- **Both modes are Raft**, so snapshots work in `dev` too.
- **The script only automates a recovery threshold of 1.** A higher threshold
  makes it exit and tell you to run `bao operator generate-root` by hand.
- **The restore path is exercised on every deploy** (rehydrate) and weekly by
  `.github/workflows/openbao-restore-drill.yml`, which restores the newest
  snapshot into a throwaway node with nothing but the seal key and asserts
  the PKI issuer chains to the offline root.
- **Cross-cloud**: [OpenBao cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}}).
```

Remove the `sudo mkdir -p /snapshot` block and its paragraph (the script no longer requires it) and change `export APPROLE_ROLE_ID=... APPROLE_SECRET_ID=...` to `export VAULT_TOKEN=...   # admin or root; the script also accepts a JWT or AppRole`.

- In "On GCP": replace `The cluster itself is single-node \`file\` storage today` … `applies to it unchanged.` with `The cluster is single-node Raft, rehydrated from \`ogenki-435905-ogenki-openbao-snapshot\` like AWS; with \`seal_provider = "awskms"\` it is the standby for the AWS lineage.` Remove the `cert-manager AppRole's role_id is pinned` bullet.

`pki-and-secrets.md`:

- Replace the `{{< callout type="warning" >}}` about the root key being in the live mount with:

```markdown
{{< callout type="info" >}}
**One offline root, both clouds.** The root's private key has never been on a
networked system since 2026-09-02 on AWS (and since 2026-08-25 on GCP). Each
OpenBao lineage imports an intermediate the root signed offline
(`certificates/priv.aws.ogenki.io/intermediate-ca` on AWS,
`openbao-priv-gcp-intermediate-ca` on GCP). The former AWS `root-ca` secret,
which held the root key, has been deleted.
{{< /callout >}}
```

- In "Building the chain", replace the `vault_pki_secret_backend_config_ca` code block and the sentence before it (`The root's certificate and private key ...`) with the ceremony for a new intermediate (the commands from Task 14 Step 1) and: `The intermediate's certificate and key go to Secrets Manager as \`{"bundle": "..."}\` under \`certificates/priv.aws.ogenki.io/intermediate-ca\`; the certificates-only chain goes to \`certificates/priv.aws.ogenki.io/ca-chain\` as \`{"ca": "..."}\`. \`opentofu/aws/openbao/management/pki.tf\` imports the bundle as the mount's issuer.`
- In the server-certificate bullets, replace `The SAN list has **no IP address**, only \`DNS:bao.priv.aws.ogenki.io\`` with `The SAN list has **no IP address** and four names: \`bao.priv.aws.ogenki.io\`, \`bao.priv.gcp.ogenki.io\`, \`openbao.security.svc.cluster.local\`, \`openbao.security.svc\` — every name a client may connect with, including the neutral in-cluster Service and the standby's hostname.`
- In "Trusting the CA on your machine", change `--root-ca-secret-name certificates/priv.aws.ogenki.io/root-ca` to `--root-ca-secret-name certificates/priv.aws.ogenki.io/ca-chain`, and replace `Each cloud has its own offline root — ... Import both if you use both.` with `Both clouds chain to the same offline root, so one import covers both.`
- Replace the ClusterIssuer YAML in "cert-manager: issuing from the PKI" with the aws-0 manifest from Task 7 Step 2, and the two paragraphs around it with:

```markdown
A `ClusterIssuer` reaches OpenBao by the **neutral in-cluster name**
`openbao.security.svc.cluster.local` — an `ExternalName` Service in
`security/base/openbao-endpoint/` that a cluster points at its own cloud's
load balancer (local form) or, through the Tailscale operator's egress
`ProxyGroup`, at the other cloud's (remote form). It authenticates with a
**projected ServiceAccount token** against `jwt/<cluster>`: cert-manager
requests a 10-minute token with audience `openbao` for its own ServiceAccount
and POSTs it with the role name. No AppRole, no `SecretID`, nothing synced. The
CA bundle is still an `ExternalSecret`, from `certificates/<domain>/ca-chain`.
```

- Set `lastVerified: 2026-09-02` and update the description to end `and how the chain rotates. One offline root for both clouds.`

`costs.md`:

- In the AWS table change `| KMS | 3 | 3 keys: cluster encryption, OpenBao unseal, snapshot bucket |` to `| KMS | 4 | 4 keys: cluster encryption, the OpenBao seal and its eu-west-1 replica, snapshot bucket |`.
- In "The floor you pay for nothing", change `about **$23/month** keeps billing` to `about **$24/month** keeps billing` and `its 3 KMS keys` to `its 4 KMS keys (the OpenBao seal is multi-region on purpose — [ADR-0032]({{< relref "/docs/decisions/0032-openbao-store-of-record-lineage.md" >}}))`. Change the summary line `**about $23/month keeps billing` at the top to `$24`.
- In "Keeping it cheap", replace `is one \`t3.micro\`. \`mode = "ha"\` is five spot instances, and the configuration steps are identical either way.` with `is one \`t3.micro\` on single-node Raft, rebuilt from its newest snapshot on every deploy. \`mode = "ha"\` is five instances, and the configuration steps are identical either way.`
- `lastVerified: 2026-09-02`.

`foundations/aws.md`: in the OpenBao table change `| Storage backend | \`file\`, on the root volume | Raft, with \`retry_join\` auto-discovery by tag |` to `| Storage backend | Raft, single node, on the root volume | Raft, with \`retry_join\` auto-discovery by tag |`; change `| Unseal | KMS auto-unseal | KMS auto-unseal |` to `| Unseal | KMS auto-unseal, key from the lineage stack | same |`. Replace `So the default posture is a single node whose OpenBao data *and* server TLS private key both sit on one encrypted gp3 root volume.` with `So the default posture is a single Raft node whose data and server TLS private key both sit on one encrypted gp3 root volume — and whose data is rebuilt from the lineage's newest snapshot on every deploy.` Add a row to the stack table for `opentofu/aws/openbao/lineage/` (`Security`, `Multi-region seal key, snapshot bucket, CI drill role. Persistent`). `lastVerified: 2026-09-02`.

`foundations/gcp.md`: add the row `| \`opentofu/gcp/openbao/lineage/\` | Security | Snapshot bucket (also the mirror of AWS snapshots), node and drill identities, Storage Transfer job, GitHub WIF pool. Persistent |` before the `openbao/cluster` row; change the cluster row's description to `OpenBao on Compute Engine, single-node Raft, **Cloud KMS** or the AWS seal (standby)`. `lastVerified: 2026-09-02`.

`private-access.md`: after the "The subnet router" section add:

```markdown
## Egress: a cluster reaching the other cloud's OpenBao

Pods are not tailnet devices, so a cluster consuming the *other* cloud's OpenBao
uses the Tailscale operator's **cluster egress**: an `ExternalName` Service
annotated `tailscale.com/tailnet-ip` with the active OpenBao's fixed NLB address
and `tailscale.com/proxy-group: ts-proxies` (`security/base/openbao-endpoint/remote`).
The operator rewrites the Service to its egress `ProxyGroup`, whose pods carry
the connection over the tailnet to the other cloud's subnet router. The ACL
admits `tag:k8s` to the advertised CIDRs on port 8200 for exactly this
(`opentofu/shared/tailscale/main.tf`). See
[OpenBao cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}}).
```

- [ ] **Step 5: `.doc-claims.yaml`, `CLAUDE.md`, `docs/gcp-bootstrap.md`**

**First, close the gap that lets this task be forgotten.** `.doc-claims.yaml`'s
`openbao-cluster-mode` claim keys on `mode = "dev"` in `variables.tfvars` — a
value Task 4 did not change — so `validate-doc-claims.sh` **passes right now
while six live pages still say OpenBao runs the `file` backend**, one of them
asserting "neither backup nor restore works there", which is the opposite of
true. Nothing but this plan enforces that Task 13 happens before merge. Add a
claim keyed on the thing that actually changed:

```yaml
  - id: openbao-storage-backend
    why: >-
      Both modes run Raft since the lineage design: `file` can neither take nor
      receive a snapshot, and the node is now rebuilt from one on every deploy.
      Six pages described the `file` backend, one of them stating that backup
      and restore do not work -- the exact opposite of the design's central
      claim. The mode claim below could not catch it, because `mode` did not
      change.
    source:
      file: opentofu/aws/openbao/cluster/scripts/startup_script.sh
      pattern: '^storage "([a-z]+)" \{'
    pages:
      - path: website/content/docs/platform/security/openbao.md
        must_contain: '`{value}`'
        must_not_contain:
          - 'storage type.*`file`'
          - 'neither backup nor restore works'
      - path: website/content/docs/platform/foundations/aws.md
        must_contain: 'Raft, single node'
```

Then, in the same file, change the `openbao-cluster-mode` entry's `why` to:

```yaml
    why: >-
      `mode` decides the node count — dev is one Raft node, ha is five on Raft
      with RAID-0 NVMe. Pages used to describe the ha shape as though it were
      deployed while variables.tfvars committed dev, so a reader assessing
      availability of the secrets store was actively misled.
```

and append three claims:

```yaml
  - id: openbao-seal-alias
    why: >-
      The seal key alias is the one string the cluster stack, the standby role,
      the drill role and the failover guide all agree on; a renamed alias with
      stale docs would send an operator to a key that does not exist.
    source:
      file: opentofu/aws/openbao/lineage/variables.tf
      pattern: 'default\s*=\s*"(alias/[a-z-]+)"'
    pages:
      - path: website/content/docs/platform/security/openbao.md
        must_contain: '`{value}`'
      - path: website/content/docs/guides/openbao-cross-cloud-failover.md
        must_contain: '`{value}`'

  - id: openbao-endpoint-name
    why: >-
      Every consumer addresses OpenBao by the neutral Service name; the docs
      quote it as the thing to configure, so it must match the manifest.
    source:
      file: security/base/openbao-endpoint/local/service.yaml
      pattern: '^\s+name:\s+(openbao)$'
    pages:
      - path: website/content/docs/platform/security/pki-and-secrets.md
        must_contain: '`{value}\.security\.svc\.cluster\.local`'

  - id: openbao-snapshot-schedule
    why: >-
      The snapshot cadence IS the RPO of a cross-cloud failover; the guide
      states it, so it must track the CronJob.
    source:
      file: security/base/openbao-snapshot/snapshot-cronjob.yaml
      pattern: 'schedule:\s+"0 (4) \* \* \*"'
    pages:
      - path: website/content/docs/guides/openbao-cross-cloud-failover.md
        must_contain: '0{value}:00 UTC|24 h'
```

In `CLAUDE.md`, in the **Namespace layout** paragraph of the "OpenBao" section, insert this sentence before `See \`opentofu/aws/openbao/management/namespaces.tf\``:

`OpenBao's storage is rebuilt from its newest snapshot on every deploy (the *lineage*, ADR-0032): the lineage and management stacks are never destroyed by the default \`destroy\` (\`TM_LINEAGE_DESTROY=true\` overrides), machine auth is the JWT method on \`jwt/<cluster>\`, and consumers reach it at \`openbao.security.svc.cluster.local:8200\`. `

In `docs/gcp-bootstrap.md`, in "What is NOT a prerequisite", append: `The snapshot bucket and the \`openbao-node\` / \`openbao-drill\` service accounts are created by \`opentofu/gcp/openbao/lineage\`; the bucket is imported from the Crossplane-era object on first apply (see the Stage 1 plan, Task 15).` And in the prerequisites list add: `- **For a standby deploy only:** the AWS lineage's root token and recovery keys copied into \`openbao-priv-gcp-root-token\` and \`openbao-priv-gcp-recovery-keys\` — see the failover guide.`

- [ ] **Step 6: Validate**

```bash
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
(cd website && hugo --minify --quiet 2>&1 | tail -5) || true
```

Expected: links resolve; claims pass (fix any regex that does not match the wording you wrote — the claim is the contract, the wording is negotiable); hugo builds with no errors (skip if `hugo` is not installed locally; CI's `docs-check.yml` runs it).

- [ ] **Step 7: Commit**

```bash
git add website/content/docs .doc-claims.yaml CLAUDE.md docs/gcp-bootstrap.md
git commit -m "docs: ADR-0032 (OpenBao lineage), amendments to 0025/0027, failover guide, page updates

Records the store-of-record decision with its rejected alternatives,
amends ADR-0025's target statement and ADR-0027's class table, adds the
cross-cloud failover runbook, and updates the OpenBao, PKI & Secrets,
costs, foundations and private-access pages plus three doc claims."
```

---

## Live tasks

Everything above is offline and merges as one PR (or one PR per task; Tasks 6 and 7 must land together). The tasks below run against the clouds, **in this order**, on the branch after the offline tasks are committed. Record every command's real output in `docs/superpowers/specs/2026-09-02-openbao-store-of-record-verification.md` as you go — that file is what `/verify-spec` completes after merge.

### Task 14 [LIVE]: AWS PKI ceremony — a new intermediate under the offline root, a new server certificate, the commitment of the root certificate

**Files:**
- Create: `.github/openbao-root-ca.pem` (the root **certificate** — public)
- Secrets Manager writes: `certificates/priv.aws.ogenki.io/intermediate-ca`, `certificates/priv.aws.ogenki.io/ca-chain`, `certificates/priv.aws.ogenki.io/openbao` (updated)

The offline root and its key are the ones the GCP ceremony produced on 2026-08-25 (`docs/superpowers/specs/2026-08-25-gcp-openbao-verification.md` records where the key was kept). Perform this on the offline medium; only certificates and the intermediate key leave it, and the intermediate key leaves only into Secrets Manager.

- [ ] **Step 1: Sign an AWS intermediate**

```bash
set -euo pipefail
work=$(mktemp -d); cd "$work"
# root-ca.pem and root-ca-key.pem: from the offline medium.
cat > intermediate-ca.cnf <<'EOF'
[ v3_req ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
openssl ecparam -genkey -name secp384r1 -out intermediate-ca-key.pem
openssl req -new -key intermediate-ca-key.pem -subj "/CN=Ogenki AWS Intermediate CA/O=Ogenki/C=FR" -out intermediate-ca.csr
openssl x509 -req -in intermediate-ca.csr -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial \
  -out intermediate-ca.pem -days 1827 -sha384 -extfile intermediate-ca.cnf -extensions v3_req
openssl verify -CAfile root-ca.pem intermediate-ca.pem
```

Expected: `intermediate-ca.pem: OK`.

- [ ] **Step 2: Issue OpenBao's server certificate with the four SANs**

```bash
cat > server.cnf <<'EOF'
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:bao.priv.aws.ogenki.io, DNS:bao.priv.gcp.ogenki.io, DNS:openbao.security.svc.cluster.local, DNS:openbao.security.svc
EOF
openssl ecparam -genkey -name prime256v1 -out server-key.pem && chmod 600 server-key.pem
openssl req -new -key server-key.pem -subj "/CN=bao.priv.aws.ogenki.io/O=Ogenki/C=FR" -out server.csr
openssl x509 -req -in server.csr -CA intermediate-ca.pem -CAkey intermediate-ca-key.pem -CAcreateserial \
  -out server.pem -days 825 -sha256 -extfile server.cnf -extensions v3_req
cat intermediate-ca.pem root-ca.pem > ca-chain.pem
openssl verify -CAfile root-ca.pem -untrusted intermediate-ca.pem server.pem
openssl x509 -in server.pem -noout -ext subjectAltName
```

Expected: `server.pem: OK` and the four DNS names.

- [ ] **Step 3: Write the three Secrets Manager entries**

```bash
jq -n --rawfile c intermediate-ca.pem --rawfile k intermediate-ca-key.pem '{bundle: ($c + $k)}' > intermediate.json
jq -n --rawfile ca ca-chain.pem '{ca: $ca}' > chain.json
jq -n --rawfile cert server.pem --rawfile key server-key.pem --rawfile ca ca-chain.pem '{cert: $cert, key: $key, ca: $ca}' > server.json
aws secretsmanager create-secret --region eu-west-3 --name certificates/priv.aws.ogenki.io/intermediate-ca --secret-string file://intermediate.json
aws secretsmanager create-secret --region eu-west-3 --name certificates/priv.aws.ogenki.io/ca-chain --secret-string file://chain.json
aws secretsmanager put-secret-value --region eu-west-3 --secret-id certificates/priv.aws.ogenki.io/openbao --secret-string file://server.json
```

Expected: three `ARN`s printed. Then copy `root-ca.pem` (the **certificate** only) into the repo as `.github/openbao-root-ca.pem`, and:

```bash
shred -u intermediate-ca-key.pem server-key.pem intermediate.json server.json 2>/dev/null || rm -f intermediate-ca-key.pem server-key.pem intermediate.json server.json
```

- [ ] **Step 4: Commit the public root**

```bash
git add .github/openbao-root-ca.pem
git commit -m "chore(pki): commit the offline root certificate for the restore drill to verify against"
```

**Do not delete `certificates/priv.aws.ogenki.io/root-ca` yet** — Task 17 does, after the new chain has issued a certificate.

### Task 14b [LIVE]: GCP server-certificate re-issue — the neutral name `gcp-0` now connects by

**Files:**
- Modify: `opentofu/gcp/openbao/cluster/dns.tf` (the comment about SANs)
- Secret Manager write: `openbao-priv-gcp-server-cert` (new version)

**Why this is not optional, and not drill-specific.** Task 7 pointed `gcp-0`'s
`ClusterIssuer` at `https://openbao.security.svc.cluster.local:8200` and gave that
cluster an `openbao` ExternalName Service — in *both* postures, GCP-only and standby.
So cert-manager on `gcp-0` performs TLS verification against a certificate that must
carry `openbao.security.svc.cluster.local`, and the GCP leaf issued by the 2026-08-25
ceremony carries only `bao.priv.gcp.ogenki.io`. Without this task, `gcp-0`'s issuer
fails with `x509: certificate is valid for bao.priv.gcp.ogenki.io, not
openbao.security.svc.cluster.local` — the same dead end as a missing token grant, one
layer down.

GCP has its own intermediate (`openbao-priv-gcp-intermediate-ca`) under the same
offline root, so this signs against that intermediate — not the AWS one from Task 14.
Perform it on the offline medium if you no longer hold the GCP intermediate's key
outside Secret Manager.

- [ ] **Step 1: Re-issue with the same four SANs**

```bash
set -euo pipefail
work=$(mktemp -d); cd "$work"
gcloud secrets versions access latest --secret openbao-priv-gcp-intermediate-ca \
  --project ogenki-435905 | jq -r .bundle > int-bundle.pem
gcloud secrets versions access latest --secret openbao-priv-gcp-ca-chain \
  --project ogenki-435905 | jq -r .ca > ca-chain.pem
# Split the bundle: the certificate first, then the key.
openssl x509 -in int-bundle.pem -out intermediate-ca.pem
openssl pkey -in int-bundle.pem -out intermediate-ca-key.pem && chmod 600 intermediate-ca-key.pem

cat > server.cnf <<'EOF'
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:bao.priv.gcp.ogenki.io, DNS:bao.priv.aws.ogenki.io, DNS:openbao.security.svc.cluster.local, DNS:openbao.security.svc
EOF
openssl ecparam -genkey -name prime256v1 -out server-key.pem && chmod 600 server-key.pem
openssl req -new -key server-key.pem -subj "/CN=bao.priv.gcp.ogenki.io/O=Ogenki/C=FR" -out server.csr
openssl x509 -req -in server.csr -CA intermediate-ca.pem -CAkey intermediate-ca-key.pem -CAcreateserial \
  -out server.pem -days 825 -sha256 -extfile server.cnf -extensions v3_req
openssl verify -CAfile ca-chain.pem server.pem
openssl x509 -in server.pem -noout -ext subjectAltName
```

Expected: `server.pem: OK` and all four DNS names. The CN stays
`bao.priv.gcp.ogenki.io` — the GCP node's own address, so nothing already trusting
that name has to change. `bao.priv.aws.ogenki.io` is in the list for the same reason
the AWS leaf carries the GCP name: either node may answer for either address during a
failover, and a certificate is cheaper to over-scope now than to re-issue mid-incident.

- [ ] **Step 2: Store it and shred the key material**

```bash
jq -n --rawfile cert server.pem --rawfile key server-key.pem --rawfile ca ca-chain.pem \
  '{cert: $cert, key: $key, ca: $ca}' > server.json
gcloud secrets versions add openbao-priv-gcp-server-cert --project ogenki-435905 --data-file=server.json
shred -u server-key.pem intermediate-ca-key.pem int-bundle.pem server.json 2>/dev/null \
  || rm -f server-key.pem intermediate-ca-key.pem int-bundle.pem server.json
cd - && rm -rf "$work"
```

Expected: a new version number printed. The node reads this secret at boot, so it
picks the new leaf up on the next start — Task 18 Step 3 already stops and starts the
instance, which is the cheapest way to make it take effect.

- [ ] **Step 3: Correct the DNS comment that says there is one SAN**

`opentofu/gcp/openbao/cluster/dns.tf`'s header states the certificate carries
`DNS:bao.priv.gcp.ogenki.io` and that "this record and the certificate's SAN have to
agree exactly". After Step 1 there are four SANs and this record matches one of them.
The load-bearing half of that comment is still true and worth keeping: there is **no
IP SAN**, so a client that connects to the load balancer by address cannot verify TLS,
and the name is the only way in. Rewrite it to say that, and to say that the other
three SANs exist for the in-cluster Service name and for cross-cloud failover.

```bash
git commit -F <msgfile> -- opentofu/gcp/openbao/cluster/dns.tf
```

### Task 15 [LIVE]: Apply the lineage stacks and import the existing buckets

- [ ] **Step 1: AWS lineage — import, then apply**

```bash
cd opentofu/aws/openbao/lineage
tofu init
tofu import -var-file=variables.tfvars aws_s3_bucket.snapshot eu-west-3-ogenki-openbao-snapshot
tofu import -var-file=variables.tfvars aws_s3_bucket_server_side_encryption_configuration.snapshot eu-west-3-ogenki-openbao-snapshot
tofu import -var-file=variables.tfvars aws_s3_bucket_lifecycle_configuration.snapshot eu-west-3-ogenki-openbao-snapshot
KEY_ID=$(aws kms describe-key --region eu-west-3 --key-id alias/xplane-openbao-snapshot --query KeyMetadata.KeyId --output text)
tofu import -var-file=variables.tfvars aws_kms_key.snapshot "$KEY_ID"
tofu import -var-file=variables.tfvars aws_kms_alias.snapshot alias/xplane-openbao-snapshot
tofu plan -var-file=variables.tfvars
```

Expected plan: **creates** `aws_kms_key.seal`, both `aws_kms_alias.seal*`, `aws_kms_replica_key.seal`, `aws_s3_bucket_public_access_block.snapshot`, `aws_s3_bucket_versioning.snapshot`, the GitHub OIDC provider, role and policy; **updates in place** the imported key (rotation on, deletion window 30) and possibly bucket tags; **no destroys**. If it wants to destroy or replace the bucket, stop — the import is wrong.

```bash
terramate script run deploy
tofu output
```

Record `seal_key_id`, `drill_role_arn`. Set the repository variable `AWS_DRILL_ROLE_ARN`.

- [ ] **Step 2: GCP lineage — import, then apply (first pass, no transfer job)**

```bash
cd ../../../gcp/openbao/lineage
TM_CLOUD=gcp terramate script run init
tofu import -var-file=variables.tfvars google_storage_bucket.snapshot ogenki-435905-ogenki-openbao-snapshot
tofu plan -var-file=variables.tfvars
```

Expected: **no destroy** of the bucket; creates the two service accounts, IAM members, WIF pool and provider. Then:

```bash
TM_CLOUD=gcp terramate script run deploy
tofu output
```

Record `openbao_node_sa_unique_id`, `transfer_agent_subject_id`, `drill_workload_identity_provider`, `drill_service_account_email`. Set repository variables `GCP_DRILL_WIF_PROVIDER` and `GCP_DRILL_SERVICE_ACCOUNT`.

- [ ] **Step 3: Remove the Crossplane MRs from the live clusters** — they are gone from Git already (Tasks 3 and 8); when Flux prunes them the objects are orphaned, not deleted. Confirm after the next Flux reconcile:

```bash
kubectl get bucket.s3.aws.m.upbound.io,key.kms.aws.m.upbound.io -n security 2>&1 | grep -c openbao-snapshot; echo "expect 0"
aws s3 ls s3://eu-west-3-ogenki-openbao-snapshot/ | tail -1
```

### Task 16 [LIVE]: Federation second pass, then the GCP transfer job

- [ ] **Step 1: Give the federation stack the two GCP subject IDs**

In `opentofu/shared/aws-gcp-federation/variables.tfvars` set `gcp_openbao_standby_sa_unique_id` and `gcp_transfer_agent_subject_id` to the values recorded in Task 15 Step 2, commit, then:

```bash
cd opentofu/shared/aws-gcp-federation && terramate script run deploy && tofu output
```

Expected: `openbao_standby_seal_role_arn` and `openbao_snapshot_mirror_role_arn` non-empty.

- [ ] **Step 2: Create the transfer job**

In `opentofu/gcp/openbao/lineage/variables.tfvars` set `aws_mirror_role_arn` to the mirror role ARN, commit, then:

```bash
cd opentofu/gcp/openbao/lineage && TM_CLOUD=gcp terramate script run deploy
gcloud transfer jobs list --project ogenki-435905 --format='value(name,description)'
gcloud transfer jobs run "$(gcloud transfer jobs list --project ogenki-435905 --format='value(name)' | head -1)" --project ogenki-435905
sleep 90; gcloud storage ls gs://ogenki-435905-ogenki-openbao-snapshot/ | tail -3
```

Expected: the job exists; after the manual run the newest S3 object name appears in the GCS listing. If the run fails with an AWS `AccessDenied`, the token's audience/subject mapping differs from the design's assumption (risk 9 in the design): inspect the STS error, and adjust the `oaud` condition in `google-identity.tf` to the claim the failure reports.

### Task 17 [LIVE]: AWS deploy — the lineage's first snapshot, then destroy and rehydrate

- [ ] **Step 1: Deploy the platform on the branch**

```bash
cd opentofu && TF_VAR_flux_git_ref='refs/heads/worktree-openbao-lineage' terramate script run deploy
```

**Before deploying, check the bucket.** `dev` mode never took a snapshot, but an earlier `ha` experiment may have left objects sealed by a key that no longer exists; rehydrate would try the newest one and fail at unseal. Run `aws s3 ls s3://eu-west-3-ogenki-openbao-snapshot/`; if anything is listed and nothing there is wanted, `aws s3 rm s3://eu-west-3-ogenki-openbao-snapshot/ --recursive`. Then deploy, and watch the management stack's output for `No snapshot in eu-west-3-ogenki-openbao-snapshot: first deploy of this lineage`. Then:

```bash
export VAULT_ADDR=https://bao.priv.aws.ogenki.io:8200 VAULT_CACERT=opentofu/aws/openbao/management/.tls/ca.pem
bao status | grep -E 'Initialized|Sealed|Storage Type'      # true / false / raft
bao login -method=userpass username=admin
bao auth list | grep -E '^jwt/aws-0/|^approle/'              # jwt/aws-0 present, approle absent
bao secrets list | grep -E '^lineage/|^pki_private_issuer/'
kubectl get clusterissuer openbao -o jsonpath='{.status.conditions[0].status}{"\n"}'   # True
kubectl get certificate -A
openssl s_client -connect bao.priv.aws.ogenki.io:8200 -showcerts </dev/null 2>/dev/null | openssl x509 -noout -issuer   # the AWS intermediate
kubectl create job -n security --from=cronjob/openbao-snapshot drill-$(date +%s) && sleep 60 && kubectl logs -n security -l job-name --tail=20
aws s3 ls s3://eu-west-3-ogenki-openbao-snapshot/ | tail -1
```

Expected: everything as annotated; the manual snapshot job logs `Authenticating with OpenBao via auth/jwt/aws-0 as role openbao-snapshot`, `Stamping lineage/check_timestamp`, and a new object appears.

**Settle the `aud` question before trusting the ClusterIssuer's verdict.** cert-manager's
`serviceAccountRef.audiences` are *extra*: the vendored CRD says "the default token
consisting of the issuer's namespace and name is always included", so the token
cert-manager mints carries a **two-element** `aud` array — `vault://openbao` plus
`openbao` — against a role bound to `openbao` alone. OpenBao's JWT method matches if
*any* audience in the token is in `bound_audiences`, so this should pass; it is
unverified against this build, and it is three commands to know rather than guess:

```bash
kubectl -n security create token cert-manager --audience openbao --duration 10m > /tmp/t
cut -d. -f2 /tmp/t | base64 -d 2>/dev/null | jq '{iss, sub, aud, exp}'
bao write auth/jwt/aws-0/login role=cert-manager jwt=@/tmp/t
```

Expected: `sub` is `system:serviceaccount:security:cert-manager`, `aud` is an **array**,
and the login returns a token with `token_policies` including `cert-manager`. Note that
`kubectl create token` produces a *single*-audience token, so it proves the role's
subject and issuer bindings but not the two-element case — read `aud` off the real
request instead if this passes and the ClusterIssuer still does not: `bao read
sys/internal/counters/activity` is no help here, the cert-manager log line is
(`kubectl logs -n security deploy/cert-manager | grep -i audience`).

If the login fails specifically on the audience (`error validating token: invalid
audience (aud) claim`), the one-line fix is in `opentofu/aws/eks/configure/openbao.tf`:

```hcl
bound_audiences = [var.openbao_jwt_audience, "vault://openbao"]
```

and the same for `jwt/gcp-0` in `opentofu/gcp/gke/configure/openbao.tf`. Prefer that to
dropping `audiences` from the ClusterIssuer — an unrestricted token is worse than a
second permitted value. Record which branch you took in the verification doc; it decides
whether Stage 2's other JWT consumers need the same pair.

- [ ] **Step 2: Delete the old root secret**

Only now, with a certificate issued by the new chain:

```bash
aws secretsmanager delete-secret --region eu-west-3 --secret-id certificates/priv.aws.ogenki.io/root-ca --force-delete-without-recovery
aws secretsmanager describe-secret --region eu-west-3 --secret-id certificates/priv.aws.ogenki.io/root-ca 2>&1 | grep -c ResourceNotFoundException   # 1
```

Also delete the two AppRole entries and the snapshot entry, which nothing reads any more:

```bash
for s in openbao/cloud-native-ref/approles/cert-manager security/openbao/openbao-snapshot; do
  aws secretsmanager delete-secret --region eu-west-3 --secret-id "$s" --force-delete-without-recovery; done
```

Re-trust your machine: `./scripts/openbao-config.sh ca --region eu-west-3 --root-ca-secret-name certificates/priv.aws.ogenki.io/ca-chain --ca-output-file /tmp/ogenki-ca.pem` and import per the PKI & Secrets page.

- [ ] **Step 3: Destroy and redeploy — the rehydrate proof**

```bash
ISSUER_BEFORE=$(curl -s --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki_private_issuer/ca/pem" | openssl x509 -noout -fingerprint -sha256)
cd opentofu && terramate script run --reverse destroy
```

Expected in the output: the management stack prints `[skip] ... lineage state`, the cluster stack prints `Pre-destroy snapshot stored in eu-west-3-ogenki-openbao-snapshot.` before destroying. The lineage stack prints `[skip]`. Then:

```bash
TF_VAR_flux_git_ref='refs/heads/worktree-openbao-lineage' terramate script run deploy
```

Expected in the management stack's output: `Snapshot <name> found ... Initialising with throwaway shares, then restoring.`, `The restored snapshot was taken 0 day(s) ago.`, `PKI issuer present: subject=CN=Ogenki AWS Intermediate CA...`, `Rehydrated from <name>.`; then `tofu apply` reports `No changes.` for the management stack (design risk 4 — if it reports changes, record which resources and whether a targeted `import`/`state rm` fixes them). Then:

```bash
ISSUER_AFTER=$(curl -s --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki_private_issuer/ca/pem" | openssl x509 -noout -fingerprint -sha256)
[ "$ISSUER_BEFORE" = "$ISSUER_AFTER" ] && echo "SAME ISSUER: rehydrate proven"
```

Expected: `SAME ISSUER: rehydrate proven` — success criterion 1 of the design.

- [ ] **Step 4: Run the drill once by hand**

Trigger `.github/workflows/openbao-restore-drill.yml` with `workflow_dispatch` on the branch (or merge first). Expected: green, with `mirror OK` in the last step. This is success criterion 7.

### Task 18 [LIVE]: The cross-cloud drill — GCP standby restores the AWS lineage

- [ ] **Step 1: Prepare the GCP bootstrap tier for a standby**

```bash
aws secretsmanager get-secret-value --region eu-west-3 --secret-id openbao/cloud-native-ref/tokens/root --query SecretString --output text \
  | gcloud secrets versions add openbao-priv-gcp-root-token --project ogenki-435905 --data-file=-
aws secretsmanager get-secret-value --region eu-west-3 --secret-id openbao/cloud-native-ref/tokens/recovery --query SecretString --output text \
  | gcloud secrets versions add openbao-priv-gcp-recovery-keys --project ogenki-435905 --data-file=-
```

(Task 14b must already be done. The drill itself connects by `bao.priv.gcp.ogenki.io`, which the original leaf covers — but `gcp-0`'s own `ClusterIssuer` connects by the neutral Service name in *both* postures, so a standby brought up without Task 14b comes back with a working OpenBao and a cert-manager that cannot talk to it.)

- [ ] **Step 2: Deploy the standby**

Follow the failover guide's step 2 (`seal_provider = "awskms"`, the key ID and role ARN from Tasks 15–16), with `TM_CLOUD=gcp terramate script run deploy` from `opentofu/`. Expected in the GCP management output: `Snapshot <name> found in ogenki-435905-ogenki-openbao-snapshot`, `Rehydrated from <name>.`

- [ ] **Step 3: Assert**

```bash
export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200 VAULT_CACERT=opentofu/gcp/openbao/management/.tls/ca.pem
bao status | grep -E 'Sealed|Storage Type'                     # false / raft
curl -s --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki_private_issuer/ca/pem" | openssl x509 -noout -subject   # the AWS intermediate
INSTANCE=$(gcloud compute instances list --project ogenki-435905 --filter='name~openbao' --format='value(name,zone)' | head -1)
gcloud compute instances stop $INSTANCE --project ogenki-435905 && gcloud compute instances start $INSTANCE --project ogenki-435905
sleep 120; bao status | grep Sealed                            # false, no operator input
```

Expected as annotated — success criterion 6. If the node stays sealed, `gcloud compute ssh` in and read `journalctl -u openbao -u openbao-aws-token`: an `AccessDenied` from STS means the `sub`/`oaud` conditions in the standby role do not match the token (design risk 3); `bao` logging `WebIdentityErr` means the token file is missing (timer).

- [ ] **Step 4: Tear the standby down and record**

```bash
cd opentofu && TM_CLOUD=gcp TM_OPENBAO_SKIP_SNAPSHOT=true terramate script run --reverse destroy
```

(`TM_OPENBAO_SKIP_SNAPSHOT=true` because a standby snapshot must not land in the GCP bucket as the "newest" object and be mirrored back over the AWS lineage's history — its contents are the AWS snapshot plus the drill's writes.) Revert `seal_provider` to `gcpckms` in the GCP tfvars and roll the GCP root-token and recovery-key secrets back to the GCP lineage's own values if you keep GCP-only mode.

Write the drill record into the verification doc: snapshot object, measured RPO, wall time for steps 2–3, and every deviation.

---

## Stage 1 exit checklist

From the design's exit criteria. Every line needs a fresh command and its output in the verification doc.

- [ ] Destroy + redeploy of AWS brings back the same `pki_private_issuer` issuer fingerprint with no seeding step (Task 17 Step 3).
- [ ] `aws kms describe-key --key-id alias/openbao-seal --region eu-west-3 --query 'KeyMetadata.[MultiRegion,MultiRegionConfiguration.ReplicaKeys[0].Region]'` → `[true, "eu-west-1"]`.
- [ ] `bao auth list` shows `jwt/aws-0/` and no `approle/`; `aws secretsmanager list-secrets --query 'SecretList[?contains(Name, `approles`)].Name'` → `[]`.
- [ ] `openssl s_client` against `bao.priv.aws.ogenki.io:8200` and (on a two-cloud run) `bao.priv.gcp.ogenki.io:8200` both chain to the committed `.github/openbao-root-ca.pem`; `describe-secret` on `root-ca` → `ResourceNotFoundException`.
- [ ] Every S3 object older than the drill's grace window has a same-size twin in `gs://ogenki-435905-ogenki-openbao-snapshot/` (Task 16 Step 2 checks the newest by hand once; the drill checks the newest settled one every week).
- [ ] GCP standby with `seal_provider = awskms` reports `Sealed: false` after stop/start (Task 18).
- [ ] The drill workflow has one green run against a CronJob-taken snapshot (Task 17 Step 4).
- [ ] `./scripts/validate-manifests.sh` → `Invalid: 0, Skipped: 0`; `check-substitution.py`, `validate-links.sh`, `validate-doc-claims.sh` → exit 0.
- [ ] Costs page re-measured: idle floor within $2 of $23 (design success criterion 8; run the same measurement the page describes and update the numbers if they moved).

When every box is ticked, open the PR (PR description per the user's global template: before/after values first, "what it does not do", a Test Plan quoting these outputs). Stage 2 gets its own plan after review of the verification doc.
