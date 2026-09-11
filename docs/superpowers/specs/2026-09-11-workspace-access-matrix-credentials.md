# Workspace access matrix — the reconciler's Google credentials

**Date:** 2026-09-11
**Status:** proven. Keyless domain-wide delegation works; no service-account key is needed.
**Design:** [2026-09-11-workspace-access-matrix-design.md](2026-09-11-workspace-access-matrix-design.md)
**Plan:** Task 6 of [the reconciler plan](../plans/2026-09-11-workspace-access-matrix-reconciler.md)

The spec flagged keyless domain-wide delegation as the one part of the credential path
not already in use in this repo, and required it to be proven before anything was built
on it. This note is that proof.

## Outcome

- The IAM Credentials API signed the delegation JWT, so no key material exists anywhere.
- The `jwt-bearer` exchange at `oauth2.googleapis.com/token` returned a token acting as
  the subject.
- With that token, the Directory API read all four matrix groups (HTTP 200).

The fallback, a service-account key in the secret store, is **not needed**. It is not
created, and the reconciler must not use one.

## What exists

| Thing | Value |
|---|---|
| GCP project | `ogenki-435905` |
| Service account | `access-matrix-sync@ogenki-435905.iam.gserviceaccount.com`, with **no project roles** |
| Its OAuth client ID | `104897059432762820483` (not a secret; it is the service account's unique ID) |
| APIs enabled | `admin.googleapis.com` (Directory), `iamcredentials.googleapis.com` (signJwt) |
| Workspace delegation | that client ID, authorised for exactly `https://www.googleapis.com/auth/admin.directory.group.readonly` |
| Caller's IAM | `roles/iam.serviceAccountTokenCreator` **on the service account only** |
| `GOOGLE_SUBJECT` | a Workspace super-admin account, the owner's choice for now |

**Why a super-admin subject is acceptable.** A delegated token carries the subject's admin
rights *intersected with* the authorised scope. With only the read-only groups scope
authorised, the reconciler can list group members and nothing else, whoever the subject
is. The least-privilege refinement is a dedicated user holding a custom "Groups: Read"
admin role. It is optional, and it costs one Workspace license.

## The commands that worked

These are run from a workstation authenticated as an identity holding
`roles/iam.serviceAccountTokenCreator` on the service account:

```bash
SA=access-matrix-sync@ogenki-435905.iam.gserviceaccount.com
SUBJECT=<GOOGLE_SUBJECT>
SCOPE=https://www.googleapis.com/auth/admin.directory.group.readonly

now=$(date +%s)
claim=$(jq -nc --arg iss "$SA" --arg sub "$SUBJECT" --arg scope "$SCOPE" \
  --argjson iat "$now" --argjson exp "$((now + 3600))" \
  '{iss:$iss, sub:$sub, scope:$scope, aud:"https://oauth2.googleapis.com/token",
    iat:$iat, exp:$exp}')

# Signed by the IAM Credentials API -- no key on disk.
assertion=$(gcloud iam service-accounts sign-jwt --quiet --iam-account="$SA" \
  <(printf '%s' "$claim") /dev/stdout)

# The assertion and the token are bearer credentials: stdin, never argv.
TOKEN=$(printf 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=%s' "$assertion" \
  | curl -sS -X POST https://oauth2.googleapis.com/token --data-binary @- \
  | jq -r '.access_token')

printf 'Authorization: Bearer %s' "$TOKEN" \
  | curl -sS -H @- \
    'https://admin.googleapis.com/admin/directory/v1/groups/platform@ogenki.io/members'
```

This is the same flow as `google_token` and `list_group_members` in
`scripts/access-matrix-sync.sh`.

## What the Directory API actually returned

Membership as of 2026-09-11:

| Group | HTTP | Members | `type` | `status` | `nextPageToken` |
|---|---|---|---|---|---|
| `platform@ogenki.io` | 200 | 1 | `USER` | `ACTIVE` | absent |
| `backend@ogenki.io` | 200 | 0 | — | — | absent |
| `data-eng@ogenki.io` | 200 | 0 | — | — | absent |
| `frontend@ogenki.io` | 200 | 0 | — | — | absent |

The live values are `USER` and `ACTIVE`, which are exactly the ones the reconciler accepts.
Any other member type or status makes a team unreadable by design, so with today's
membership no team is refused. Repeat this check before the first `--apply`, because
membership will have changed by then.

## Gotchas met on the way

- **Enabling an API can silently not land.** The first `gcloud services enable
  admin.googleapis.com` did not take effect on `ogenki-435905`. Every group read then
  failed with `403 Admin SDK API has not been used in project … or it is disabled`,
  while the token exchange still succeeded. Confirm with `gcloud services list --enabled`,
  not with the command's exit status.
- **A successful token exchange proves the delegation, not the API.** Google issues the
  delegated token only when the client ID and scope pair is authorised. Whether the
  Directory API is reachable is a separate question.

## Not proven here, left for Task 9

This proof ran as a **workstation** identity. The CronJob's pod needs the same single
role (`roles/iam.serviceAccountTokenCreator` on the service account) through its own
identity:

- on gcp-0, Workload Identity;
- on aws-0, the `opentofu/shared/aws-gcp-federation` stack.

That path is unproven until Task 9 deploys it. `gcloud` is also not required in the image:
`signJwt` is a plain REST call,
`POST https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/<sa>:signJwt`.
