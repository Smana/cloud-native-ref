oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

_region = envConfig.region

_metadata = lambda suffix: str -> any {
    {
        name = oxr.metadata.name + "-" + suffix
        namespace = oxr.metadata.namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-" + suffix
        }
    }
}
# Set the instance size
if oxr.spec.size == "small":
    _instanceResources = {
        requests: {
            cpu: "0.5"
            memory: "1Gi"
        }
        limits: {
            cpu: "1"
            memory: "1Gi"
        }
    }
elif oxr.spec.size == "medium":
    _instanceResources = {
        requests: {
            cpu: "1"
            memory: "3Gi"
        }
        limits: {
            cpu: "2"
            memory: "3Gi"
        }
    }
elif oxr.spec.size == "large":
    _instanceResources = {
        requests: {
            cpu: "2"
            memory: "8Gi"
        }
        limits: {
            cpu: "4"
            memory: "8Gi"
        }
    }

_items = []

_postgresVersion = oxr.spec.postgresVersion if oxr.spec.postgresVersion else "18"
_imageName = "ghcr.io/cloudnative-pg/postgresql:" + _postgresVersion + "-system-trixie"

# Performance Insights: Auto-managed monitoring configuration
# When performanceInsights is enabled, CloudNativePG automatically manages:
#   - pg_stat_statements (adds to shared_preload_libraries + CREATE EXTENSION)
#   - auto_explain (adds to shared_preload_libraries)
#   - Query plan capture with correlation via compute_query_id

# Helper variables for defaults (handles None/0/0.0 correctly using typeof)
# Production-safe defaults: 20% sampling, 1s threshold, no statement logging
_minDuration = oxr.spec.performanceInsights?.explain?.minDuration
_minDurationValue = _minDuration if typeof(_minDuration) == "int" else 1000
_sampleRate = oxr.spec.performanceInsights?.explain?.sampleRate
_sampleRateValue = _sampleRate if typeof(_sampleRate) == "float" or typeof(_sampleRate) == "int" else 0.2
_logStatement = oxr.spec.performanceInsights?.logStatement
_logStatementValue = _logStatement if typeof(_logStatement) == "str" else "none"

_performanceInsightsParams = {
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # pg_stat_statements - AUTO-MANAGED by CloudNativePG
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    "pg_stat_statements.max": "10000"
    "pg_stat_statements.track": "all"
    "pg_stat_statements.track_utility": "on"
    "pg_stat_statements.track_planning": "on"
    "pg_stat_statements.save": "on"
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # auto_explain - AUTO-MANAGED by CloudNativePG
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # CRITICAL: JSON format for parsing
    "auto_explain.log_format": "json"
    # Minimum duration threshold (configurable: -1=disabled, 0=all, >0=threshold in ms)
    "auto_explain.log_min_duration": str(_minDurationValue)
    # Include actual runtime statistics
    "auto_explain.log_analyze": "on"
    # Include buffer I/O statistics
    "auto_explain.log_buffers": "on"
    # Reduce overhead (no per-node timing)
    "auto_explain.log_timing": "off"
    # Include trigger execution time
    "auto_explain.log_triggers": "on"
    # Maximum detail in plan output
    "auto_explain.log_verbose": "on"
    # Include nested statements
    "auto_explain.log_nested_statements": "on"
    # Sample rate for query plan capture (configurable)
    "auto_explain.sample_rate": str(_sampleRateValue)
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # CORRELATION KEY: compute_query_id (PostgreSQL 14+)
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # Enables "Query Identifier" in EXPLAIN JSON output
    # This is the pivot key between pg_stat_statements and auto_explain logs
    "compute_query_id": "on"
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # Statement Logging: Log SQL statements (configurable)
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # Controls which SQL statements are logged
    # - none (default): No statement logging, rely on auto_explain
    # - ddl: Log DDL statements (CREATE, ALTER, DROP)
    # - mod: Log DDL + data modifications (INSERT, UPDATE, DELETE)
    # - all: Log ALL statements (WARNING: high overhead, 10-30%)
    "log_statement": _logStatementValue
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # Additional monitoring parameters
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # Capture longer query text
    "track_activity_query_size": "2048"
    # Enable I/O timing statistics
    "track_io_timing": "on"
    # NOTE: shared_preload_libraries is AUTO-MANAGED by CloudNativePG operator
    # The operator automatically adds auto_explain and pg_stat_statements when it detects their parameters
    # Log slow queries (ms)
    "log_min_duration_statement": "1000"
    # Consistent log format
    "log_line_prefix": "%m [%p] %u@%d "
    # Log connections (debugging)
    "log_connections": "on"
    # Log disconnections (debugging)
    "log_disconnections": "on"
}

_items = []

# Create ConfigMap with pg_stat_statements custom queries when performanceInsights is enabled
if oxr.spec.performanceInsights?.enabled:
    _items += [{
        apiVersion = "v1"
        kind = "ConfigMap"
        metadata = {
            name = oxr.metadata.name + "-cnpg-monitoring"
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-cnpg-monitoring-configmap"
                "krm.kcl.dev/ready" = "True"
            }
        }
        data = {
            queries = """pg_stat_statements:
  query: |
    SELECT
      d.datname as database,
      r.rolname as user,
      s.queryid::text as query_id,
      LEFT(s.query, 200) as query,
      s.calls,
      s.total_exec_time,
      s.mean_exec_time,
      s.min_exec_time,
      s.max_exec_time,
      s.stddev_exec_time,
      s.rows,
      s.shared_blks_hit,
      s.shared_blks_read,
      s.local_blks_read,
      s.temp_blks_read,
      s.shared_blk_read_time as blk_read_time,
      s.shared_blk_write_time as blk_write_time
    FROM pg_stat_statements s
    JOIN pg_database d ON s.dbid = d.oid
    JOIN pg_roles r ON s.userid = r.oid
    WHERE d.datname NOT IN ('template0', 'template1', 'postgres')
    AND s.queryid IS NOT NULL
    ORDER BY s.mean_exec_time DESC
    LIMIT 100
  metrics:
    - database:
        usage: "LABEL"
        description: "Database name"
    - user:
        usage: "LABEL"
        description: "User name"
    - query_id:
        usage: "LABEL"
        description: "Query identifier (compute_query_id) for correlation with auto_explain"
    - query:
        usage: "LABEL"
        description: "Query text (truncated)"
    - calls:
        usage: "COUNTER"
        description: "Number of times executed"
    - total_exec_time:
        usage: "COUNTER"
        description: "Total execution time in milliseconds"
    - mean_exec_time:
        usage: "GAUGE"
        description: "Mean execution time in milliseconds"
    - min_exec_time:
        usage: "GAUGE"
        description: "Minimum execution time in milliseconds"
    - max_exec_time:
        usage: "GAUGE"
        description: "Maximum execution time in milliseconds"
    - stddev_exec_time:
        usage: "GAUGE"
        description: "Standard deviation of execution time"
    - rows:
        usage: "COUNTER"
        description: "Total rows retrieved or affected"
    - shared_blks_hit:
        usage: "COUNTER"
        description: "Shared blocks cache hits"
    - shared_blks_read:
        usage: "COUNTER"
        description: "Shared blocks read from disk"
    - local_blks_read:
        usage: "COUNTER"
        description: "Local blocks read from disk"
    - temp_blks_read:
        usage: "COUNTER"
        description: "Temp blocks read"
    - blk_read_time:
        usage: "COUNTER"
        description: "Time reading blocks (ms)"
    - blk_write_time:
        usage: "COUNTER"
        description: "Time writing blocks (ms)"
"""
        }
    }]

_items += [
    {
        apiVersion = "postgresql.cnpg.io/v1"
        kind = "Cluster"
        metadata = {
            name = oxr.metadata.name + "-cnpg-cluster"
            namespace = oxr.metadata.namespace
        }
        spec = {
            instances = oxr.spec.instances
            imageName = _imageName
            primaryUpdateStrategy = oxr.spec.primaryUpdateStrategy
            if oxr.spec.createSuperuser:
                enableSuperuserAccess = True
            if oxr.spec.initSQL or oxr.spec.databases or oxr.spec.objectStoreRecovery:
                bootstrap = {
                    if oxr.spec.objectStoreRecovery:
                        recovery: {
                            source: oxr.spec.objectStoreRecovery.path
                        }
                    else:
                        initdb = {
                            if oxr.spec.databases:
                                database = oxr.spec.databases[0].name
                                owner = oxr.spec.databases[0].owner
                                secret = {
                                    name = oxr.metadata.name + "-cnpg-" + oxr.spec.databases[0].name
                                }
                            if oxr.spec.initSQL:
                                postInitApplicationSQLRefs = {
                                    configMapRefs = [
                                        {
                                            name = oxr.metadata.name + "-cnpg-bootsrapsql"
                                            key = "init.sql"
                                        }
                                    ]
                                }
                        }
                }
            if oxr.spec.backup:
                backup = {
                    barmanObjectStore = {
                        destinationPath = "s3://" + oxr.spec.backup.bucketName
                        s3Credentials = {
                            inheritFromIAMRole = True
                        }
                        wal = {
                            compression = "bzip2"
                        }
                        data = {
                            compression = "bzip2"
                        }
                    }
                    retentionPolicy = oxr.spec.backup.retentionPolicy
                }
            if oxr.spec.createSuperuser:
                superuserSecret = {
                    name = oxr.metadata.name + "-cnpg-superuser"
                }
            storage = {
                size = oxr.spec.storageSize
                storageClassName = oxr.spec.storageClassName
            }
            monitoring = {
                enablePodMonitor = True
                if oxr.spec.performanceInsights?.enabled:
                    customQueriesConfigMap = [
                        {
                            name = oxr.metadata.name + "-cnpg-monitoring"
                            key = "queries"
                        }
                    ]
                    disableDefaultQueries = False
            }
            resources = _instanceResources
            # Merge PostgreSQL configuration
            # Priority: performanceInsights params < user-provided parameters
            if oxr.spec.performanceInsights?.enabled or oxr.spec.postgresql:
                postgresql = {
                    if oxr.spec.performanceInsights?.enabled or oxr.spec.postgresql?.parameters:
                        parameters = {
                            # Apply performance insights params if enabled
                            if oxr.spec.performanceInsights?.enabled:
                                **_performanceInsightsParams
                            # User parameters override performance insights
                            if oxr.spec.postgresql?.parameters:
                                **oxr.spec.postgresql.parameters
                        }
                    if oxr.spec.postgresql?.pg_hba:
                        pg_hba = oxr.spec.postgresql.pg_hba
                }
            if oxr.spec.objectStoreRecovery:
                externalClusters = [
                    {
                        name = oxr.spec.objectStoreRecovery.path
                        barmanObjectStore = {
                            destinationPath = "s3://" + oxr.spec.objectStoreRecovery.bucketName
                            s3Credentials = {
                                inheritFromIAMRole = True
                            }
                            wal: {
                                maxParallel: 8
                            }
                        }
                    }
                ]
            if oxr.spec.roles:
                managed.roles = [{
                    name = role.name
                    comment = role.comment
                    login = True
                    superuser = role.superuser
                    inRoles = role.inRoles
                    passwordSecret = {
                        # Use the database secret (same credentials, named after database not role)
                        name = oxr.metadata.name + "-cnpg-" + [db.name for db in oxr.spec.databases if db.owner == role.name][0]
                    }
                } for role in oxr.spec.roles]
        }
    }
]

# Create ExternalSecrets for database owners (used by initdb, roles, and applications)
# Each database gets a secret named after the database (not the role) to support CNPG initdb bootstrap
if oxr.spec.databases:
    _items += [{
        apiVersion = "external-secrets.io/v1"
        kind = "ExternalSecret"
        metadata = {
            name = oxr.metadata.name + "-cnpg-" + db.name
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-cnpg-externalsecret-" + db.name
            }
        }
        spec = {
            refreshInterval = "30m"
            secretStoreRef = {
                kind = "ClusterSecretStore"
                name = "clustersecretstore"
            }
            data = [
                {
                    secretKey = "username"
                    remoteRef = {
                        key = "cnpg/" + oxr.metadata.name + "/roles/" + db.owner
                        property = "username"
                    }
                }
                {
                    secretKey = "password"
                    remoteRef = {
                        key = "cnpg/" + oxr.metadata.name + "/roles/" + db.owner
                        property = "password"
                    }
                }
            ]
            target = {
                creationPolicy = "Owner"
                deletionPolicy = "Retain"
                name = oxr.metadata.name + "-cnpg-" + db.name
                if oxr.spec.atlasSchema:
                    template = {
                        engineVersion = "v2"
                        data = {
                            username = "{{ .username }}"
                            password = "{{ .password }}"
                            uri = "postgresql://{{ .username | urlquery }}:{{ .password | urlquery }}@" + oxr.metadata.name + "-cnpg-cluster-rw." + oxr.metadata.namespace + ".svc:5432/" + db.name
                        }
                    }
            }
        }
    } for db in oxr.spec.databases]

# Create databases
if oxr.spec.databases:
    _items += [{
        apiVersion = "postgresql.cnpg.io/v1"
        kind = "Database"
        metadata = {
            name = oxr.metadata.name + "-cnpg-" + db.name
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/ready": "True"
            } if ocds?[oxr.metadata.name + "-cnpg-" + db.name]?.Resource?.status?.applied == True else {}
        }
        spec = {
            name = db.name
            owner = db.owner
            cluster = {
                name = oxr.metadata.name + "-cnpg-cluster"
            }
        }
    } for db in oxr.spec.databases]

    # Atlas Schema Migrations per database - GitOps Pattern
    # When atlasSchema is defined, creates a complete migration pipeline per database:
    # 1. GitRepository - Flux pulls migration files from Git (url, ref, path)
    # 2. Kustomization - Generates ConfigMap from migrations using configMapGenerator
    # 3. AtlasMigration - Applies migrations using ConfigMap reference
    
    # Helper: Conditional suffix for Atlas resources to avoid name duplication
    # When there's only one database, omit the database name from resource names
    # Example: xplane-image-gallery-atlas-migrations-repo (single DB)
    #          xplane-image-gallery-db1-atlas-migrations-repo (multiple DBs)
    _atlasNameSuffix = lambda dbName: str -> str {
        "" if len(oxr.spec.databases) == 1 else "-" + dbName
    }

    if oxr.spec.atlasSchema:
        # Validate required atlasSchema fields
        assert oxr.spec.atlasSchema.url, "atlasSchema.url is required when atlasSchema is enabled"
        assert oxr.spec.atlasSchema.ref, "atlasSchema.ref is required when atlasSchema is enabled"
        assert oxr.spec.atlasSchema.path, "atlasSchema.path is required when atlasSchema is enabled"

        # GitRepository per database
        _items += [{
            apiVersion = "source.toolkit.fluxcd.io/v1"
            kind = "GitRepository"
            metadata = {
                name = oxr.metadata.name + _atlasNameSuffix(db.name) + "-atlas-migrations-repo"
                namespace = oxr.metadata.namespace
            }
            spec = {
                interval = "10m"
                url = oxr.spec.atlasSchema.url
                ref = {
                    if oxr.spec.atlasSchema.ref.startswith("v"):
                        tag = oxr.spec.atlasSchema.ref
                    else:
                        branch = oxr.spec.atlasSchema.ref
                }
            }
        } for db in oxr.spec.databases]

        # Kustomization per database
        _items += [{
            apiVersion = "kustomize.toolkit.fluxcd.io/v1"
            kind = "Kustomization"
            metadata = {
                name = oxr.metadata.name + _atlasNameSuffix(db.name) + "-atlas-migrations-configmap"
                namespace = oxr.metadata.namespace
            }
            spec = {
                interval = "10m"
                sourceRef = {
                    kind = "GitRepository"
                    name = oxr.metadata.name + _atlasNameSuffix(db.name) + "-atlas-migrations-repo"
                }
                path = oxr.spec.atlasSchema.path
                prune = True
                targetNamespace = oxr.metadata.namespace
            }
        } for db in oxr.spec.databases]

        # AtlasMigration per database
        _items += [{
            apiVersion = "db.atlasgo.io/v1alpha1"
            kind = "AtlasMigration"
            metadata = {
                name = oxr.metadata.name + _atlasNameSuffix(db.name) + "-atlas-migration"
                namespace = oxr.metadata.namespace
            }
            spec = {
                urlFrom = {
                    secretKeyRef = {
                        key = "uri"
                        # Connect using the database secret
                        name = oxr.metadata.name + "-cnpg-" + db.name
                    }
                }
                dir = {
                    configMapRef = {
                        name = "atlas-db-migrations"
                    }
                }
            }
        } for db in oxr.spec.databases]


if oxr.spec.initSQL:
    _initSQL = oxr.spec.initSQL

    _items += [
        {
            apiVersion = "v1"
            kind = "ConfigMap"
            metadata = {
                name = oxr.metadata.name + "-cnpg-bootsrapsql"
                namespace = oxr.metadata.namespace
            }
            data = {
                "init.sql" = _initSQL
            }
        }
    ]

# Create superuser secret if requested
if oxr.spec.createSuperuser:
    _items += [
        {
            apiVersion = "external-secrets.io/v1"
            kind = "ExternalSecret"
            metadata = {
                name = oxr.metadata.name + "-cnpg-superuser"
                namespace = oxr.metadata.namespace
            }
            spec = {
                data = [
                    {
                        secretKey = "username"
                        remoteRef = {
                            key = "cnpg/" + oxr.metadata.name + "/superuser"
                            property = "username"
                        }
                    }
                    {
                        secretKey = "password"
                        remoteRef = {
                            key = "cnpg/" + oxr.metadata.name + "/superuser"
                            property = "password"
                        }
                    }
                ]
                refreshInterval = "30m"
                secretStoreRef = {
                    kind = "ClusterSecretStore"
                    name = "clustersecretstore"
                }
                target = {
                    name = oxr.metadata.name + "-cnpg-superuser"
                    template = {
                        type = "kubernetes.io/basic-auth"
                        data = {
                            username = '{{.username}}'
                            password = '{{.password}}'
                        }
                    }
                }
            }
        }
    ]
elif oxr.spec.createSuperuser and oxr.spec.atlasSchema:
    # Atlas Schema Migrations for superuser mode (when no databases are defined) - GitOps Pattern
    # When atlasSchema is defined with superuser only, creates a migration pipeline:
    # 1. GitRepository - Flux pulls migration files from Git
    # 2. Kustomization - Generates ConfigMap from migrations
    # 3. AtlasMigration - Applies migrations using superuser credentials
    
    # Validate required atlasSchema fields
    assert oxr.spec.atlasSchema.url, "atlasSchema.url is required when atlasSchema is enabled"
    assert oxr.spec.atlasSchema.ref, "atlasSchema.ref is required when atlasSchema is enabled"
    assert oxr.spec.atlasSchema.path, "atlasSchema.path is required when atlasSchema is enabled"

    _items += [
        {
            apiVersion = "source.toolkit.fluxcd.io/v1"
            kind = "GitRepository"
            metadata = {
                name = oxr.metadata.name + "-atlas-migrations-repo"
                namespace = oxr.metadata.namespace
            }
            spec = {
                interval = "10m"
                url = oxr.spec.atlasSchema.url
                ref = {
                    if oxr.spec.atlasSchema.ref.startswith("v"):
                        tag = oxr.spec.atlasSchema.ref
                    else:
                        branch = oxr.spec.atlasSchema.ref
                }
            }
        }
        {
            apiVersion = "kustomize.toolkit.fluxcd.io/v1"
            kind = "Kustomization"
            metadata = {
                name = oxr.metadata.name + "-atlas-migrations-configmap"
                namespace = oxr.metadata.namespace
            }
            spec = {
                interval = "10m"
                sourceRef = {
                    kind = "GitRepository"
                    name = oxr.metadata.name + "-atlas-migrations-repo"
                }
                path = oxr.spec.atlasSchema.path
                prune = True
                targetNamespace = oxr.metadata.namespace
            }
        }
        {
            apiVersion = "db.atlasgo.io/v1alpha1"
            kind = "AtlasMigration"
            metadata = {
                name = oxr.metadata.name + "-atlas-migration"
                namespace = oxr.metadata.namespace
            }
            spec = {
                urlFrom = {
                    secretKeyRef = {
                        key = "uri"
                        # Use superuser secret for migrations
                        name = oxr.metadata.name + "-cnpg-superuser"
                    }
                }
                dir = {
                    configMapRef = {
                        name = "atlas-db-migrations"
                    }
                }
            }
        }
    ]

# Create daily backups using EKS pod identity for AWS auth
if oxr.spec.backup?.schedule:
    _backupResources = [
        {
            apiVersion = "postgresql.cnpg.io/v1"
            kind = "ScheduledBackup"
            metadata = {
                name = oxr.metadata.name + "-cnpg-daily-backup"
                namespace = oxr.metadata.namespace
                # We need this annotations because there aren't any field status that tells the resource is healthy
                annotations = {
                    "krm.kcl.dev/ready": "True"
                }
            }
            spec = {
                schedule = oxr.spec.backup.schedule
                backupOwnerReference = "self"
                cluster = {
                    name = oxr.metadata.name + "-cnpg-cluster"
                }
            }
        }
        {
            apiVersion = "iam.aws.m.upbound.io/v1beta1"
            kind = "Role"
            metadata = _metadata("cnpg-iam-role")
            spec: {
                forProvider = {
                    assumeRolePolicy = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
"""
                }
            }
        }
        {
            apiVersion = "iam.aws.m.upbound.io/v1beta1"
            kind = "Policy"
            metadata = _metadata("cnpg-iam-policy")
            spec: {
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
                forProvider = {
                    policy = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::${oxr.spec.backup.bucketName}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:*"
            ],
            "Resource": "arn:aws:s3:::${oxr.spec.backup.bucketName}/*"
        }
    ]
}
"""
                }
            }
        }
        {
            apiVersion = "iam.aws.m.upbound.io/v1beta1"
            kind = "RolePolicyAttachment"
            metadata = _metadata("cnpg-iam-role-policy-attachment")
            spec: {
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
                forProvider = {
                    policyArnSelector = {
                        matchControllerRef = True
                    }
                    roleSelector = {
                        matchControllerRef: True
                    }
                }
            }
        }
        {
            apiVersion = "eks.aws.m.upbound.io/v1beta1"
            kind = "PodIdentityAssociation"
            metadata = _metadata("cnpg-pod-identity-association")
            spec: {
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
                forProvider = {
                    clusterName = envConfig.clusterName
                    serviceAccount = oxr.metadata.name + "-cnpg-cluster"
                    namespace = oxr.metadata.namespace
                    region = _region
                    roleArnSelector = {
                        matchControllerRef = True
                    }
                }
            }
        }
    ]
    _items += _backupResources

items = _items
