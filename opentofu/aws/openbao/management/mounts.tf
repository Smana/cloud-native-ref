resource "vault_mount" "app_secret" {
  namespace   = vault_namespace.app.path_fq
  path        = "secret"
  type        = "kv-v2"
  description = "Store sensitive data"
}

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

# Store of record for platform component secrets (Stage 2 of ADR-0033).
#
# Root namespace, deliberately. A policy binds only within the namespace it is
# created in, and the `oidc/` mount, the identity groups and every policy this
# platform has are in root. A mount in a child namespace cannot be reached by
# any of them -- which is exactly why the `app` namespace mount above was never
# usable by a human and is consumed by nothing.
#
# Grammar: platform/<component>/<name>, one-to-one onto ADR-0023's dash names.
# `harbor-admin-password` becomes `platform/harbor/admin-password`.
resource "vault_mount" "platform" {
  path        = "platform"
  type        = "kv-v2"
  description = "Platform component secrets; store of record (ADR-0033 Stage 2)"
}

# Store of record for application secrets, owned per app.
#
# Separate from `platform/` because External Secrets' vault provider takes ONE
# mount per store (spec.provider.vault.path), so the split is what lets the two
# audiences carry different policies without prefix gymnastics inside a single
# policy document.
#
# Grammar: apps/<app>/<key>.
resource "vault_mount" "apps" {
  path        = "apps"
  type        = "kv-v2"
  description = "Application secrets, owned per app (ADR-0036)"
}
