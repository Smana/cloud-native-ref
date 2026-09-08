# OpenBao Cluster

Deploy a OpenBao instance following HashiCorp's best practices. Complete these steps in order:

1. **Server Certificates**: Prepare certificates first and store them in the expected AWS SecretsManager resources. You can provide yours or use the guide: [Building the CA chain](https://cnref.ogenki.io/docs/platform/security/pki-and-secrets/#building-the-chain).

2. **OpenBao Instance Setup**: Start your OpenBao instance. See [Cluster initialisation](https://cnref.ogenki.io/docs/platform/security/openbao/#cluster-initialisation) for instructions.

3. **Configure OpenBao**: After setting up the cluster, configure it. Switch to the [management](../management/README.md) directory for PKI, roles, etc.

## 💪 High availability

⚠️ You can choose between two modes when creating a OpenBao instance: `dev` and `ha` (default: `dev`). Here are the differences between these modes:

|                      | Dev          | HA                    |
|----------------------|--------------|-----------------------|
| Number of nodes      | 1            | 5                     |
| Disk type            | gp3 (root)   | NVMe instance store   |
| OpenBao storage type | raft (single node) | raft                  |
| Instance type(s)     | t3.micro     | mixed (lower-price)   |
| Capacity type        | on-demand    | 3 on-demand + 2 ~95% spot |

Both modes are Raft since the lineage design (2026-09): a `file` backend cannot take
or receive a snapshot, and the node is rebuilt from the lineage's newest snapshot on
every deploy — see [OpenBao](https://cnref.ogenki.io/docs/platform/security/openbao/).

Architectural decisions:

1. **Raft Protocol for Cluster Reliability**: Utilizing the Raft protocol, recognized for its robustness in distributed systems, to ensure cluster reliability.

2. **Five-Node Cluster Configuration**: Following best practices for fault tolerance and availability when using the Raft protocol. All five overrides are equally weighted — ASG reads `desired_capacity` as *capacity units*, so unequal `weighted_capacity` values would make the node count (and therefore the quorum size) depend on which spot pool won.

3. **Ephemeral Node Strategy with SPOT Instances**: Multiple instance pools, so an interrupted Spot Instance is replaced from a different pool.

4. **Data Storage on RAID0 Array**: RAID-0 across the instance-store NVMe devices, for throughput.

5. **OpenBao Auto-Unseal**: AWS KMS, so a replaced node rejoins without manual intervention.

### ⚠️ This is a demo posture, not a production one

This cluster is torn down and reprovisioned on every platform test, and points 3 and 4
above are priced for that. **Do not carry them into a long-lived deployment.** Concretely,
in `ha` mode:

- **Two of the five voters run on spot.** `on_demand_base_capacity = 3`
  (`autoscaling_group.tf`) pins the quorum majority to on-demand, and
  `on_demand_percentage_above_base_capacity = 5` leaves the two nodes above that base
  ~95% spot. So a correlated reclamation costs fault tolerance, not the leader election
  — but the cluster then runs with no margin, and the ephemeral data path below is what
  makes that matter. This bullet said `on_demand_base_capacity = 0` and "every voter is
  interruptible" until 2026-09-08; that was the shape before the 2026-08-19 HA bring-up
  failed on `InsufficientInstanceCapacity`, and the comment above the setting records
  why it changed.
- **The Raft data path is ephemeral.** `/opt/openbao/data` is a RAID-0 of instance-store
  NVMe (`scripts/setup-local-disks.sh`). Instance store does not survive a stop/start or a
  replacement, and RAID-0 means a single failed device loses that node's entire store.
  Combined with the point above, a bad enough spot event is total data loss, not a
  degraded cluster.
- **Nothing removes dead Raft peers.** There is no terminate lifecycle hook calling
  `bao operator raft remove-peer` and no autopilot `cleanup_dead_servers` configuration,
  so replaced nodes linger in the peer set as dead voters. Spot churn accumulates them.
  The `OpenBaoRaftQuorumAtRisk` alert
  (`observability/base/victoria-metrics-k8s-stack/vmrules/openbao.yaml`) is what tells you
  this is happening.

For a deployment meant to stay up: take the last two voters off spot as well, put the
Raft path on encrypted gp3 EBS, and add a lifecycle hook that deregisters the peer before
the instance goes away. The first of those is already half done — the quorum majority is
on-demand — which is why it is one item here rather than three.

## 🔭 Observability

The instances are scraped twice: host metrics via the node exporter on `:9100`
(`vmscrapeconfigs/ec2.yaml`, EC2 service discovery) and OpenBao's own
`/v1/sys/metrics` through the internal NLB (`vmscrapeconfigs/openbao.yaml`).

The OpenBao scrape verifies TLS against the CA chain on purpose. That makes an expired or
mis-issued server certificate fail the scrape and fire `OpenBaoDown`, rather than passing
silently the way a `skip_tls_verify` client would.

Because the instance security group now admits `:8200` from the NLB only, the OpenBao
scrape targets the load balancer by DNS rather than discovering instances by IP. Each
scrape therefore lands on whichever node the NLB picks — exact for single-node `dev`,
but `ha` needs per-node scraping: add an ingress rule for `:8200` from the pod CIDR and
swap the static target for an `ec2SDConfigs` block filtered on `tag:app=openbao`.

## 🔒 Security Considerations

* Keep the Root CA offline. ✅ It is. One offline root signed each cloud's intermediate
  once, only the intermediate's cert+key is imported into the `pki` mount, and the
  Secrets Manager entry that used to hold the root key is deleted — see the note in
  [management/README.md](../management/README.md), which this line contradicted until
  2026-09-08. The weekly restore drill re-checks the chain against the committed root
  certificate on every run.
* Use hardened AMIs, such as those built with [this project](https://github.com/konstruktoid/hardened-images) from @konstruktoid. An Ubuntu AMI from Canonical is used by default.
* Disable SSM once the cluster is operational and an Identity provider is configured.
* Implement MFA for authentication. ⚠️ Still not enforced — but not for the reason this
  line used to give. It claimed "the only identity is the root token in Secrets Manager",
  that no OIDC method was configured, and that the `admin` policy was "bound to nothing".
  All three are false: human login is ZITADEL OIDC
  (`management/oidc.tf`, [ADR-0034](https://cnref.ogenki.io/docs/decisions/0034-openbao-oidc-via-zitadel-project-roles/),
  conditional only on the ZITADEL client id and issuer being set), the `userpass` admin
  (`management/auth.tf`) survives deliberately as break-glass carrying the `admin` and
  `pki-admin` policies, and machines authenticate through the per-cluster JWT mounts.
  What remains true is narrower: routing human login through OIDC makes MFA a ZITADEL
  **login-policy** setting rather than an OpenBao one, and nothing in this repo sets it.
  The break-glass `userpass` credential would sit outside it either way.

### Secrets never travel in user-data

The server certificate, its private key and the CA chain are fetched from AWS Secrets
Manager by `scripts/startup_script.sh` at boot, under an instance-role policy scoped to
that single secret ARN.

They used to be templated into `scripts/cloudinit-config.yaml`, which put the **server
private key into the launch template's `user_data`** — readable by every process on the
instance through IMDS, by any principal holding `ec2:DescribeLaunchTemplateVersions`, and
in plaintext in the OpenTofu state file. The instance role carried the
`AmazonEC2ReadOnlyAccess` managed policy at the time, which grants exactly that
permission, so a process on an OpenBao node could read back its own TLS private key.

Three things keep that closed:

* `cloudinit-config.yaml` contains no secrets and no template variables.
* The instance role grants `ec2:DescribeInstances` (all Raft `auto_join` needs) instead of
  `AmazonEC2ReadOnlyAccess`, plus `secretsmanager:GetSecretValue` on one ARN.
* `http_put_response_hop_limit` is `1`, not `32`, so IMDS cannot be reached through a
  proxy or container hop chain.

### Boot-time downloads

The boot script still installs OpenBao, the AWS CLI and the node exporter from the network.
The OpenBao `.deb` is signature-checked against a **pinned** GPG fingerprint
(`66D15FDD87287219C8E15478D200CD702853E6D0`) — previously the key was refetched every boot
and trusted on sight, which proved only that the key and the binary came from the same
place. The AWS CLI comes from snap, which verifies its own packages.

Baking an AMI removes this whole class of problem, along with the `package_upgrade: true`
that makes every boot non-deterministic. That is the recommended next step; the script sets
`set -euo pipefail` so a failed download fails the boot rather than yielding a half-built
node, and the ASG's `ELB` health check then replaces it.
