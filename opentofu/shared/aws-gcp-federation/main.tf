# Cross-cloud identity federation: AWS trusts GKE-issued ServiceAccount tokens.
#
# This is the ONLY place in the platform where a workload authenticates to the
# other cloud, and it does so with NO material at rest -- no access key, no
# secret in GCP Secret Manager, nothing to rotate. cert-manager and external-dns
# on gcp-0 present a projected ServiceAccount token; AWS STS validates it against
# the OIDC provider below and returns short-lived credentials.
#
# WHY THIS LIVES IN shared/ RATHER THAN aws/: these are AWS resources that exist
# solely to couple the two clouds, which is what shared/ already means here --
# opentofu/shared/tailscale holds the tailnet for the same reason. Filing it
# under aws/ would present a federation point as AWS's own concern and hide it
# from anyone reading the GCP tree.

locals {
  # Deterministic from project/location/name -- it does NOT require the cluster
  # to exist, which is what keeps this stack independent of the GCP stacks and
  # free of a cross-cloud remote-state read.
  #
  # It also means a cluster REBUILD does not break the federation: same project,
  # location and name produce the same issuer, and AWS re-fetches the JWKS from
  # the discovery endpoint, so rotated signing keys are handled. What DOES break
  # it is renaming the cluster, moving it to another zone, or moving projects --
  # all of which change this URL and require the provider to be recreated.
  oidc_issuer = "https://container.googleapis.com/v1/projects/${var.gcp_project_id}/locations/${var.gcp_cluster_location}/clusters/${var.gcp_cluster_name}"
}

# LOOKUP, never a resource. The zone is not managed by this repository -- see
# opentofu/aws/eks/configure/data.tf, which reads it the same way.
data "aws_route53_zone" "public" {
  name         = var.public_domain_name
  private_zone = false
}

# This fetches the TLS certificate of the HOST (container.googleapis.com), not
# of the cluster-specific path in oidc_issuer. That succeeds for ANY URL on that
# host, including one whose /clusters/<name> segment 404s -- confirmed 2026-08-25
# with gcp-0 not deployed: the discovery URL 404s but this data source would
# still resolve, because the certificate it fetches belongs to the shared GKE API
# frontend, not to a specific cluster.
#
# So a wrong project, location or cluster name here does NOT fail this apply. It
# produces an aws_iam_openid_connect_provider that creates cleanly and points at
# an issuer nothing will ever answer for. Nothing fails until cert-manager
# presents a token and gets back an opaque AWS AccessDenied that never mentions
# the issuer -- the apply succeeding proves the host has a cert, not that the
# cluster path is correct. That is why Task 5 Step 1 re-verifies the full
# discovery URL against a live gcp-0 before this stack is applied there: this
# data source cannot catch that class of mistake on its own.
data "tls_certificate" "gke_oidc" {
  url = "${local.oidc_issuer}/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "gke" {
  url             = local.oidc_issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.gke_oidc.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gke.arn]
    }

    # The audience cert-manager requests by default, and what external-dns is
    # configured with. Without this the role would accept a token minted for
    # ANY audience, which is the classic confused-deputy shape.
    condition {
      test     = "StringEquals"
      variable = "${replace(local.oidc_issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The membership of the trust: only these ServiceAccounts, by exact subject.
    condition {
      test     = "StringEquals"
      variable = "${replace(local.oidc_issuer, "https://", "")}:sub"
      values   = [for sa in var.trusted_service_accounts : "system:serviceaccount:${split("/", sa)[0]}:${split("/", sa)[1]}"]
    }
  }
}

resource "aws_iam_role" "route53" {
  name               = "gcp-0-route53-dns"
  description        = "Assumed by cert-manager and external-dns on GKE cluster gcp-0 to manage records in ${var.public_domain_name}"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "route53" {
  # Record changes in ONE zone. Not zone creation, not deletion, not
  # reconfiguration -- the zone is a stateful shared resource this repo does not
  # own, and the constitution forbids deletion permissions on those.
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.public.zone_id}"]
  }

  # GetChange is how ACME polls for propagation. It takes a change ID, not a
  # zone, so it cannot be narrowed to this zone's changes -- an AWS API
  # limitation, not an oversight.
  statement {
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  # external-dns resolves a domain filter to a zone ID at startup. Read-only,
  # and unavoidable for the zone-discovery path.
  statement {
    effect    = "Allow"
    actions   = ["route53:ListHostedZonesByName", "route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "route53" {
  name   = "route53-records"
  role   = aws_iam_role.route53.id
  policy = data.aws_iam_policy_document.route53.json
}
