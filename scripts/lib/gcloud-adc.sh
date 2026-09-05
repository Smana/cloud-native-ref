# shellcheck shell=bash
#
# Run gcloud as the SAME identity OpenTofu uses.
#
# Source this and call gcp_gcloud instead of gcloud:
#
#   . "$(dirname "$0")/lib/gcloud-adc.sh"
#   gcp_gcloud storage ls "gs://${BUCKET}/"
#
# WHY THIS EXISTS
#
# Everything that builds this platform on GCP authenticates with Application
# Default Credentials -- the google provider, the GCS state backend, the GKE
# calls. Scripts that shell out to plain `gcloud` do not: they use the CLI
# account from `gcloud config get-value account`. Two identities, one workflow,
# and nothing says so until one of them is missing a grant.
#
# On 2026-08-29 that cost most of a day. A `gcloud auth login` had filed a
# personal-account credential under a Workspace name, so every stored credential
# resolved to an account with NO bindings on the project, while ADC was the
# project Owner. Errors read
#
#   [smaine.kahlouch@ogenki.io] does not have permission ...
#   smaine.kahlouch@gmail.com does not have storage.objects.list access
#
# -- gcloud printing the configured label while Google evaluated a different
# token. It broke openbao-config.sh mid-deploy and cnpg-prepare-restore.sh after
# it, both with permission errors that pointed at IAM rather than at the CLI.
#
# CLOUDSDK_AUTH_ACCESS_TOKEN makes gcloud use a token we hand it. When ADC is not
# configured we fall back to the CLI account, which is the old behaviour and
# still correct on a workstation that only ever runs `gcloud auth login`.
#
# Factored out rather than copied per script: this repository has already learned
# what happens to a snippet duplicated across files -- the GCP opt-in gate became
# fifteen hand-written copies and four scripts silently missed it.

_gcloud_adc_token=""
_gcloud_adc_resolved="false"

# Resolve the ADC token ONCE per shell. Shared by gcp_gcloud and
# gcp_gcloud_token so the two cannot drift, and so a script using both still
# pays for exactly one `print-access-token`.
#
# The separate $_gcloud_adc_resolved flag is not redundant with testing the
# token for emptiness: EMPTY IS A LEGITIMATE RESOLVED VALUE -- "no ADC on this
# box, fall back to the CLI account" -- and testing the token instead would
# re-run print-access-token on every call on such a box.
_gcloud_adc_resolve() {
    if [ "$_gcloud_adc_resolved" = "false" ]; then
        _gcloud_adc_token=$(gcloud auth application-default print-access-token 2>/dev/null || true)
        _gcloud_adc_resolved="true"
    fi
}

gcp_gcloud() {
    _gcloud_adc_resolve
    if [ -n "$_gcloud_adc_token" ]; then
        CLOUDSDK_AUTH_ACCESS_TOKEN="$_gcloud_adc_token" gcloud "$@"
    else
        gcloud "$@"
    fi
}

# Say which identity is in play, ON STDERR.
#
# The redirect is load-bearing: callers capture gcp_gcloud's stdout as data --
# a secret value, a bucket listing -- and a log line written to stdout lands
# inside it. That put a timestamped line into .tls/ca.pem once already, where it
# failed TLS verification in a way that pointed at the certificate rather than at
# the logging.
gcp_gcloud_identity() {
    if [ -n "$_gcloud_adc_token" ]; then
        echo "using Application Default Credentials (same identity as OpenTofu)" >&2
    else
        echo "no Application Default Credentials; using the gcloud CLI account" >&2
    fi
}

# The memoised token ITSELF, for a caller that has to HAND IT ON rather than run
# a gcloud command with it: openbao-config.sh's export_snapshot_env puts it in
# CLOUDSDK_AUTH_ACCESS_TOKEN for a POSIX-sh child that calls gcloud bare. That
# caller ran `print-access-token` itself, because this library exposed only the
# wrapper and the logger -- a second round-trip for a token already in hand, and
# one that could resolve differently from the one every other call in the same
# script was using.
#
# Deliberately as TOLERANT as gcp_gcloud: prints nothing and returns 0 when ADC
# is not configured, because that is a supported state on a workstation that
# only ever runs `gcloud auth login`. Callers test the result for emptiness.
gcp_gcloud_token() {
    _gcloud_adc_resolve
    printf '%s' "$_gcloud_adc_token"
}
