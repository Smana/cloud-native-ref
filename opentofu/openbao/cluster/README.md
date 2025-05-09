# OpenBao Cluster

Deploy a OpenBao instance following HashiCorp's best practices. Complete these steps in order:

1. **Server Certificates**: Prepare certificates first and store them in the expected AWS SecretsManager resources. You can provide yours or use the guide: [Public Key Infrastructure (PKI): Requirements](./docs/pki_requirements.md).

2. **OpenBao Instance Setup**: Start your OpenBao instance. See [Getting Started](./docs/getting_started.md) for instructions.

3. **Configure OpenBao**: After setting up the cluster, configure it. Switch to the [management](../management/README.md) directory for PKI, roles, etc.

## 💪 High availability

⚠️ You can choose between two modes when creating a OpenBao instance: `dev`  and `ha` (default: `dev`). Here are the differences between these modes:

|                    | Dev            |     HA        |
|--------------------|----------------|---------------|
| Number of nodes    |        1       |       5       |
| Disk type          |      hdd       |      ssd      |
| OpenBao storage type |      file      |     raft      |
| Instance type(s)   |    t3.micro    |   mixed (lower-price)    |
| Capacity type      |   on-demand    |     spot      |

In designing a production environment for HashiCorp OpenBao, I opted for a balance between performance and reliability. Key architectural decisions include:

1. **Raft Protocol for Cluster Reliability**: Utilizing the Raft protocol, recognized for its robustness in distributed systems, to ensure cluster reliability in a production environment.

2. **Five-Node Cluster Configuration**: Following best practices for fault tolerance and availability, this setup significantly reduces the risk of service disruption and is a recommended choice when using the Raft protocol.

3. **Ephemeral Node Strategy with SPOT Instances**: This approach provides operational flexibility and cost efficiency. Note that we also use multiple instance pools. When a Spot Instance in AWS Auto Scaling is interrupted, the system automatically replaces it with another available instance from a different Spot Instance pool, ensuring continuous operation while optimizing costs.

4. **Data Storage on RAID0 Array**: Prioritizing performance, RAID0 arrays offer faster data access. The Raft protocol and a robust backup/restore strategy help mitigate the lack of redundancy in RAID0.

5. **OpenBao Auto-Unseal Feature**: Configured to accommodate the ephemeral nature of nodes, ensuring minimal downtime and manual intervention.

This architecture balances performance, cost-efficiency, and resilience, embracing the dynamic nature of cloud resources for operational flexibility.

## 🔒 Security Considerations

* Keep the Root CA offline.
* Use hardened AMIs, such as those built with [this project](https://github.com/konstruktoid/hardened-images) from @konstruktoid. An Ubuntu AMI from Canonical is used by default.
* Disable SSM once the cluster is operational and an Identity provider is configured.
* Implement MFA for authentication.
