# The Stage 2 store of record (ADR-0033). Root namespace, deliberately: a policy
# binds only within the namespace it is created in, and the oidc/ mount, the
# identity groups and every policy live in root.
#
# Grammar: platform/<component>/<name>, one-to-one onto ADR-0023's dash names.
resource "vault_mount" "platform" {
  path        = "platform"
  type        = "kv-v2"
  description = "Platform component secrets; store of record (ADR-0033 Stage 2)"
}

# Separate from platform/ because External Secrets' vault provider takes ONE
# mount per store, so the split is what lets the two audiences carry different
# policies. Grammar: apps/<app>/<key>.
resource "vault_mount" "apps" {
  path        = "apps"
  type        = "kv-v2"
  description = "Application secrets, owned per app (ADR-0036)"
}
