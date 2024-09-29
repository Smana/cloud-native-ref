# Configure the databases, owners, and grants for the SQL instance
# Warning: not being tested for MariaDB
import base64

oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

if oxr.spec.parameters.engine == "postgres":
    _SQLApiVersion = "postgresql.sql.crossplane.io/v1alpha1"
    _dbPort = 5432
elif oxr.spec.parameters.engine == "mariadb":
    _SQLApiVersion = "mysql.sql.crossplane.io / v1alpha1"
    _dbPort = 3306

if oxr.spec.parameters.providerConfigName == "":
    _providerConfigName = oxr.spec.claimRef.name + "-sql-" + oxr.spec.parameters.engine
else:
    _providerConfigName = oxr.spec.parameters.providerConfigName
_metadata = lambda resourceName: str, suffix -> any {
    {
        name = resourceName
        annotations = {
            if suffix == "":
                "krm.kcl.dev/composition-resource-name" = resourceName
            else:
                "krm.kcl.dev/composition-resource-name" = resourceName + "-" + suffix
        }
    }
}

to_set = lambda items: [str] {
    [item for item in {item = None for item in items}]
}

_SQLProviderConfig = lambda dbEngine: str -> any {
    {
        apiVersion = _SQLApiVersion
        kind = "ProviderConfig"
        metadata = {
            name = _providerConfigName
            namespace = oxr.spec.claimRef.namespace
        }
        spec = {
            connectionSecretRef = {
                name = oxr.spec.claimRef.name
            }
            if dbEngine == "postgres":
                sslMode = "require"
            elif dbEngine == "mariadb":
                tls = "preferred"
            credentials = {
                if dbEngine == "postgres":
                    source = "PostgreSQLConnectionSecret"
                elif dbEngine == "mariadb":
                    source = "MySQLConnectionSecret"
                connectionSecretRef = {
                    name = oxr.spec.claimRef.name + "-rds-secret"
                    namespace = oxr.spec.claimRef.namespace
                }
            }
        }
    }
}

_SQLOwner = lambda owner: str -> any {
    {
        apiVersion = _SQLApiVersion
        if _SQLApiVersion == "postgresql.sql.crossplane.io/v1alpha1":
            kind = "Role"
        elif _SQLApiVersion == "mysql.sql.crossplane.io/v1alpha1":
            kind = "User"
        metadata = _metadata(oxr.spec.claimRef.name + "-" + owner, "owner")
        spec = {
            providerConfigRef = {
                name = _providerConfigName
            }
            if _SQLApiVersion == "postgresql.sql.crossplane.io/v1alpha1":
                forProvider = {
                    privileges = {
                        login: True
                    }
                    configurationParameters = [
                        {
                            name = "createrole_self_grant"
                            value = "set"
                        }
                    ]
                }
            writeConnectionSecretToRef = {
                name = oxr.spec.claimRef.name + "-owner-" + owner
                namespace = oxr.spec.claimRef.namespace
            }
        }
    }
}

_SQLDatabase = lambda db: any -> any {
    {
        apiVersion = _SQLApiVersion
        kind = "Database"
        metadata = _metadata(oxr.spec.claimRef.name + "-" + db.name, "database")
        spec = {
            providerConfigRef = {
                name = _providerConfigName
            }
            forProvider = {}
        }
    }
}

_SQLGrant = lambda db: any -> any {
    {
        apiVersion = _SQLApiVersion
        kind = "Grant"
        metadata = _metadata(oxr.spec.claimRef.name + "-" + db.owner + "-" + db.name, "grant")
        spec = {
            providerConfigRef.name = _providerConfigName
            forProvider = {
                privileges = [
                    "ALL"
                ]
                roleRef.name = oxr.spec.claimRef.name + "-" + db.owner
                databaseRef.name = oxr.spec.claimRef.name + "-" + db.name
            }
        }
    }
}

_items = [
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = _metadata(oxr.spec.claimRef.name + "-provider-config-" + oxr.spec.parameters.engine, "kubernetes")
        spec = {
            forProvider = {
                manifest = _SQLProviderConfig(oxr.spec.parameters.engine)
            }
        }
    }
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = _metadata(oxr.spec.claimRef.name + "-rds-secret-" + oxr.spec.parameters.engine, "kubernetes")
        spec = {
            references = [
                {
                    patchesFrom = {
                        apiVersion = "rds.aws.upbound.io/v1beta1"
                        kind = "Instance"
                        name = oxr.spec.claimRef.name + "-rds-instance"
                        namespace = oxr.spec.claimRef.namespace
                        fieldPath = "spec.forProvider.username"
                    }
                    toFieldPath = "stringData.username"
                }
                {
                    patchesFrom = {
                        apiVersion = "rds.aws.upbound.io/v1beta1"
                        kind = "Instance"
                        name = oxr.spec.claimRef.name + "-rds-instance"
                        namespace = oxr.spec.claimRef.namespace
                        fieldPath = "status.atProvider.address"
                    }
                    toFieldPath = "stringData.endpoint"
                }
                {
                    patchesFrom = {
                        apiVersion = "v1"
                        kind = "Secret"
                        name = oxr.spec.parameters.passwordSecretRef.name
                        namespace = oxr.spec.claimRef.namespace
                        fieldPath = "data.password"
                    }
                    toFieldPath = "data.password"
                }
            ]
            forProvider.manifest = {
                apiVersion = "v1"
                kind = "Secret"
                metadata = {
                    name = oxr.spec.claimRef.name + "-rds-secret"
                    namespace = oxr.spec.claimRef.namespace
                }
                data.port = base64.encode(str(_dbPort))
            }
        }
    }
]

if oxr.spec.parameters?.databases:
    # Remove duplicates
    owners = [d.owner for d in oxr.spec.parameters.databases]
    unique_owners = to_set(owners)

    _items += [_SQLOwner(owner) for owner in unique_owners]

    _items += [_SQLDatabase(_database) for _database in oxr.spec.parameters.databases]

    _items += [_SQLGrant(_database) for _database in oxr.spec.parameters.databases]

items = _items
