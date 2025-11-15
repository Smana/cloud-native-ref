# CloudNativePG KCL Module

A KCL composition function module for deploying PostgreSQL clusters using [CloudNativePG](https://cloudnative-pg.io/) on Kubernetes with Crossplane.

## Overview

This module creates a complete PostgreSQL cluster deployment with:
- CloudNativePG PostgreSQL cluster with configurable size and resources
- Automated backups to S3 with retention policies
- Database and role management
- Integration with External Secrets for credential management
- EKS Pod Identity for secure AWS access
- Optional superuser access and custom initialization SQL
- Performance insights (pg_stat_statements + auto_explain for query plan history)

## Features

- **Cluster Sizing**: Pre-configured small, medium, and large instance sizes
- **Backup Management**: Automated S3 backups with configurable schedules and retention
- **Security**: Integration with External Secrets and EKS Pod Identity
- **Database Management**: Automatic database and role creation
- **Recovery**: Support for object store recovery from existing backups
- **Monitoring**: Built-in monitoring with PodMonitor for Prometheus
- **Performance Insights**: Optional query performance monitoring with execution plan history

## Resource Sizes

| Size | CPU Request | CPU Limit | Memory Request | Memory Limit |
|------|-------------|-----------|----------------|--------------|
| small | 0.5 | 1 | 1Gi | 1Gi |
| medium | 1 | 2 | 3Gi | 3Gi |
| large | 2 | 4 | 8Gi | 8Gi |

## Examples

### Basic PostgreSQL Cluster

Create a simple 3-instance PostgreSQL cluster:

```yaml
apiVersion: postgresql.example.com/v1alpha1
kind: PostgreSQLCluster
metadata:
  name: basic-postgres
  namespace: default
spec:
  instances: 3
  size: small
  primaryUpdateStrategy: unsupervised
  storageSize: 20Gi
  storageClassName: gp3
```

### Advanced PostgreSQL Cluster with Backups and Custom Databases

```yaml
apiVersion: postgresql.example.com/v1alpha1
kind: PostgreSQLCluster
metadata:
  name: production-postgres
  namespace: production
spec:
  # Cluster configuration
  instances: 3
  size: medium
  primaryUpdateStrategy: supervised
  storageSize: 100Gi
  storageClassName: gp3

  # Enable superuser access
  createSuperuser: true

  # Configure automated backups
  backup:
    schedule: "0 2 * * *"  # Daily at 2 AM
    bucketName: my-app-postgres-backups
    retentionPolicy: "30d"

  # Custom databases and owners
  databases:
    - name: app_db
      owner: app_user
    - name: analytics_db
      owner: analytics_user

  # Custom roles with specific permissions
  roles:
    - name: app_user
      comment: "Application database user"
      superuser: false
      inRoles:
        - pg_monitor
        - pg_read_all_data
    - name: analytics_user
      comment: "Analytics read-only user"
      superuser: false
      inRoles:
        - pg_monitor
    - name: admin_user
      comment: "Database administrator"
      superuser: true

  # Initialize with extensions and custom schema
  initSQL: |
    -- Enable useful extensions
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
    CREATE EXTENSION IF NOT EXISTS uuid-ossp;

    -- Create custom schemas
    CREATE SCHEMA IF NOT EXISTS app;
    CREATE SCHEMA IF NOT EXISTS analytics;

    -- Grant schema permissions
    GRANT USAGE, CREATE ON SCHEMA app TO app_user;
    GRANT USAGE ON SCHEMA analytics TO analytics_user;

  # Management policies for drift detection
  managementPolicies:
    - Create
    - Update
    - Delete
```

### PostgreSQL Cluster with Performance Insights

Enable query performance monitoring and execution plan history:

```yaml
apiVersion: postgresql.example.com/v1alpha1
kind: PostgreSQLCluster
metadata:
  name: monitored-postgres
  namespace: production
spec:
  instances: 3
  size: medium
  storageSize: 100Gi
  storageClassName: gp3

  # Enable performance insights with production-safe defaults
  # Default values: sampleRate: 0.2 (20%), minDuration: 1000ms, logStatement: none
  performanceInsights:
    enabled: true

  backup:
    schedule: "0 2 * * *"
    bucketName: postgres-backups
```

## Configuration Reference

### Required Fields

- `instances`: Number of PostgreSQL instances (integer)
- `size`: Instance size (`small`, `medium`, or `large`)
- `storageSize`: Storage size (e.g., `20Gi`, `100Gi`)
- `storageClassName`: Kubernetes storage class name

### Optional Fields

#### Cluster Management
- `primaryUpdateStrategy`: Update strategy (`supervised` or `unsupervised`)
- `createSuperuser`: Enable superuser access (boolean)
- `managementPolicies`: Crossplane management policies (array)

#### Database Configuration
- `databases`: Array of databases to create
  - `name`: Database name (string)
  - `owner`: Database owner role (string)
- `roles`: Array of custom roles
  - `name`: Role name (string)
  - `comment`: Role description (string)
  - `superuser`: Grant superuser privileges (boolean)
  - `inRoles`: Array of roles to inherit from
- `initSQL`: Custom SQL to run during initialization (string)

#### Backup Configuration
- `backup`: Backup configuration object
  - `schedule`: Cron schedule for backups (string)
  - `bucketName`: S3 bucket name for backups (string)
  - `retentionPolicy`: Backup retention period (string, e.g., `30d`)

#### Recovery Configuration
- `objectStoreRecovery`: Recovery from existing backups
  - `path`: Recovery source path (string)
  - `bucketName`: S3 bucket containing backups (string)

#### Performance Insights
- `performanceInsights`: Enable query performance monitoring (object)
  - `enabled`: Enable performance insights (boolean, default: false)
  - `explain.sampleRate`: Sample rate for slow queries (float, default: 0.2 = 20%)
  - `explain.minDuration`: Minimum query duration to log in ms (int, default: 1000)
  - `logStatement`: SQL statement logging level (string, default: "none", options: none/ddl/mod/all)
  - Configures `pg_stat_statements` and `auto_explain` extensions (auto-managed by CloudNativePG v1.23+)
  - Enables `compute_query_id` for correlation with execution plans
  - Plans logged to VictoriaLogs with query_id for correlation
  - Performance overhead with defaults: ~5-7% CPU, ~280MB memory (production-safe)

## Prerequisites

1. **CloudNativePG Operator**: Must be installed in the cluster
2. **External Secrets Operator**: Required for credential management
3. **EKS Pod Identity**: For AWS S3 access (when using backups)
4. **S3 Bucket**: Pre-created bucket for backups (if backup is enabled)
5. **ClusterSecretStore**: Named `clustersecretstore` for External Secrets

## Secret Management

The module automatically creates External Secrets for:

### Superuser Credentials
- **Path**: `cnpg/{cluster-name}/superuser`
- **Properties**: `username`, `password`

### Role Credentials
- **Path**: `cnpg/{cluster-name}/roles/{role-name}`
- **Properties**: User-defined (typically `username`, `password`)

### Secret Store Configuration
Secrets are stored in your configured secret store (e.g., AWS Secrets Manager, HashiCorp Vault) and synchronized using External Secrets with the `clustersecretstore` ClusterSecretStore.

## IAM Permissions

When backups are enabled, the module creates IAM resources with the following S3 permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::bucket-name"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": "arn:aws:s3:::bucket-name/*"
    }
  ]
}
```

## Monitoring

The module enables PostgreSQL monitoring by default:
- **PodMonitor**: Automatically created for Prometheus scraping
- **Metrics**: CloudNativePG exposes PostgreSQL and cluster metrics
- **Integration**: Works with VictoriaMetrics and other Prometheus-compatible systems

## Troubleshooting

### Common Issues

1. **Backup Failures**: Check EKS Pod Identity association and S3 bucket permissions
2. **Secret Sync Issues**: Verify ClusterSecretStore configuration and secret paths
3. **Database Creation Failures**: Check role permissions and initialization SQL syntax
4. **Recovery Issues**: Ensure source backup path and bucket are accessible

### Useful Commands

```bash
# Check cluster status
kubectl get clusters.postgresql.cnpg.io

# View cluster details
kubectl describe cluster <cluster-name>

# Check backup status
kubectl get scheduledbackups.postgresql.cnpg.io

# View External Secret status
kubectl get externalsecrets

# Check Pod Identity associations
kubectl get podidentityassociation
```

## Version Compatibility

- **KCL**: v0.11.3+
- **CloudNativePG**: v1.20+
- **Kubernetes**: v1.25+
- **External Secrets**: v0.9+
