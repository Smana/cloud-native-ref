# Tests for CloudNativePG (SQLInstance) composition
# Run: kcl test . -Y settings-example.yaml

# ---- Test: CNPG Cluster is always created ----
test_cnpg_cluster_created = lambda {
    clusters = [r for r in items if r.kind == "Cluster" and r.apiVersion == "postgresql.cnpg.io/v1"]
    assert len(clusters) == 1, "expected exactly 1 CNPG Cluster"
    _oxr = option("params").oxr
    assert clusters[0].metadata.name == _oxr.metadata.name + "-cnpg-cluster"
    assert clusters[0].spec.instances == _oxr.spec.instances
}

# ---- Test: Instance size mapping ----
test_instance_size_resources = lambda {
    clusters = [r for r in items if r.kind == "Cluster"]
    resources = clusters[0].spec.resources
    _size = option("params").oxr.spec.size
    if _size == "small":
        assert resources.requests.cpu == "0.5", "small cpu request should be 0.5"
        assert resources.limits.memory == "1Gi", "small memory limit should be 1Gi"
    elif _size == "medium":
        assert resources.requests.cpu == "1", "medium cpu request should be 1"
        assert resources.limits.memory == "3Gi", "medium memory limit should be 3Gi"

    assert True
}

# ---- Test: Databases create ExternalSecrets and Database resources ----
test_databases_resources = lambda {
    _oxr = option("params").oxr
    dbs = _oxr.spec.databases or []
    if len(dbs) > 0:
        extSecrets = [r for r in items if r.kind == "ExternalSecret"]
        dbResources = [r for r in items if r.kind == "Database" and r.apiVersion == "postgresql.cnpg.io/v1"]
        # One ExternalSecret per database (+ superuser if enabled)
        _superuserSecrets = 1 if _oxr.spec.createSuperuser else 0
        assert len(extSecrets) == len(dbs) + _superuserSecrets, "expected {} ExternalSecrets ({}db + {}superuser), got {}".format(len(dbs) + _superuserSecrets, len(dbs), _superuserSecrets, len(extSecrets))
        assert len(dbResources) == len(dbs), "expected {} Database resources, got {}".format(len(dbs), len(dbResources))

    assert True
}

# ---- Test: Backup creates ScheduledBackup and IAM resources ----
test_backup_resources = lambda {
    _oxr = option("params").oxr
    if _oxr.spec.backup?.schedule:
        backups = [r for r in items if r.kind == "ScheduledBackup"]
        assert len(backups) == 1, "expected 1 ScheduledBackup"
        assert backups[0].spec.schedule == _oxr.spec.backup.schedule
        # IAM resources for backup
        roles = [r for r in items if r.kind == "Role"]
        assert len(roles) >= 1, "expected at least 1 IAM Role for backup"
        policies = [r for r in items if r.kind == "Policy"]
        assert len(policies) >= 1, "expected at least 1 IAM Policy for backup"
        pias = [r for r in items if r.kind == "PodIdentityAssociation"]
        assert len(pias) >= 1, "expected at least 1 PodIdentityAssociation for backup"

    assert True
}

# ---- Test: Performance insights creates monitoring ConfigMap ----
test_performance_insights = lambda {
    _oxr = option("params").oxr
    if _oxr.spec.performanceInsights?.enabled:
        cms = [r for r in items if r.kind == "ConfigMap" and "cnpg-monitoring" in r.metadata.name]
        assert len(cms) == 1, "expected 1 monitoring ConfigMap"
        assert "pg_stat_statements" in cms[0].data.queries, "monitoring queries should include pg_stat_statements"

    assert True
}

# ---- Test: Cluster has monitoring enabled ----
test_monitoring_enabled = lambda {
    clusters = [r for r in items if r.kind == "Cluster"]
    assert clusters[0].spec.monitoring.enablePodMonitor == True, "pod monitoring should be enabled"
}

# ---- Test: Atlas schema creates Flux + Atlas resources ----
test_atlas_schema_resources = lambda {
    _oxr = option("params").oxr
    if _oxr.spec.atlasSchema and _oxr.spec.databases:
        gitRepos = [r for r in items if r.kind == "GitRepository"]
        kustomizations = [r for r in items if r.kind == "Kustomization"]
        migrations = [r for r in items if r.kind == "AtlasMigration"]
        _dbCount = len(_oxr.spec.databases)
        assert len(gitRepos) == _dbCount, "expected {} GitRepository, got {}".format(_dbCount, len(gitRepos))
        assert len(kustomizations) == _dbCount, "expected {} Kustomization, got {}".format(_dbCount, len(kustomizations))
        assert len(migrations) == _dbCount, "expected {} AtlasMigration, got {}".format(_dbCount, len(migrations))

    assert True
}

# ---- Test: PostgreSQL version in image name ----
test_postgres_version = lambda {
    _oxr = option("params").oxr
    clusters = [r for r in items if r.kind == "Cluster"]
    _version = _oxr.spec.postgresVersion if _oxr.spec.postgresVersion else "18"
    assert _version in clusters[0].spec.imageName, "image should contain postgres version {}".format(_version)
}

# ---- Test: Superuser secret created when enabled ----
test_superuser_secret = lambda {
    _oxr = option("params").oxr
    if _oxr.spec.createSuperuser:
        suSecrets = [r for r in items if r.kind == "ExternalSecret" and "superuser" in r.metadata.name]
        assert len(suSecrets) == 1, "expected 1 superuser ExternalSecret"

    assert True
}

# ---- Test: Roles configuration ----
test_roles_in_cluster = lambda {
    _oxr = option("params").oxr
    if _oxr.spec.roles:
        clusters = [r for r in items if r.kind == "Cluster"]
        managedRoles = clusters[0].spec.managed.roles
        assert len(managedRoles) == len(_oxr.spec.roles), "expected {} managed roles, got {}".format(len(_oxr.spec.roles), len(managedRoles))

    assert True
}
