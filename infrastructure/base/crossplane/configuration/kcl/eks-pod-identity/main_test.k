# Tests for EKS Pod Identity composition
# Run: kcl test . -Y settings-example.yaml

# ---- Test: Core IAM resources are created ----
test_core_iam_resources = lambda {
    assert len([r for r in items if r.kind == "Role"]) == 1, "expected 1 IAM Role"
    assert len([r for r in items if r.kind == "Policy"]) == 1, "expected 1 IAM Policy"
    assert len([r for r in items if r.kind == "RolePolicyAttachment"]) >= 1, "expected at least 1 RolePolicyAttachment"
}

# ---- Test: PodIdentityAssociation per cluster ----
test_pod_identity_per_cluster = lambda {
    pias = [r for r in items if r.kind == "PodIdentityAssociation"]
    clusters = option("params").oxr.spec.clusters
    assert len(pias) == len(clusters), "expected one PodIdentityAssociation per cluster, got {} for {} clusters".format(len(pias), len(clusters))
}

# ---- Test: Resource naming convention ----
test_resource_naming = lambda {
    _name = option("params").oxr.metadata.name
    _bad = [r.metadata.name for r in items if not r.metadata.name.startswith(_name)]
    assert len(_bad) == 0, "resources with wrong prefix: {}".format(_bad)
}

# ---- Test: Additional policy attachments ----
test_additional_policy_attachments = lambda {
    additionalArns = option("params").oxr.spec.additionalPolicyArns or []
    all_attachments = [r for r in items if r.kind == "RolePolicyAttachment"]
    assert len(all_attachments) == 1 + len(additionalArns), "expected {} RolePolicyAttachments (1 base + {} additional), got {}".format(1 + len(additionalArns), len(additionalArns), len(all_attachments))
}

# ---- Test: Management policies propagation ----
test_management_policies = lambda {
    _mgmt = option("params").oxr.spec.managementPolicies
    _roles = [r for r in items if r.kind == "Role"]
    assert not _mgmt or _roles[0].spec.managementPolicies == _mgmt, "Role should have managementPolicies set"
}

# ---- Test: Provider config ref defaults ----
test_provider_config_ref = lambda {
    _providerRef = option("params").oxr.spec.providerConfigRef or {kind = "ClusterProviderConfig", name = "default"}
    _roles = [r for r in items if r.kind == "Role"]
    assert _roles[0].spec.providerConfigRef == _providerRef, "Role should use expected providerConfigRef"
}

# ---- Test: All resources have correct apiVersion ----
test_api_versions = lambda {
    _iam_resources = [r for r in items if r.kind in ["Role", "Policy", "RolePolicyAttachment"]]
    _bad_iam = [r.kind for r in _iam_resources if r.apiVersion != "iam.aws.m.upbound.io/v1beta1"]
    assert len(_bad_iam) == 0, "IAM resources with wrong apiVersion: {}".format(_bad_iam)
    _pias = [r for r in items if r.kind == "PodIdentityAssociation"]
    _bad_pia = [r.kind for r in _pias if r.apiVersion != "eks.aws.m.upbound.io/v1beta1"]
    assert len(_bad_pia) == 0, "PIA resources with wrong apiVersion: {}".format(_bad_pia)
}
