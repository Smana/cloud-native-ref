# Vault cluster

In designing our production environment for HashiCorp Vault, we prioritized both performance and reliability. This led to several key architectural decisions:

1. Cluster Reliability via Raft Protocol: We're leveraging the raft protocol for its robustness in ensuring cluster reliability. This consensus mechanism is widely recognized for its effectiveness in distributed systems and is particularly crucial in a production environment.

2. Five-Node Cluster Configuration: Best practices suggest a five-node cluster in production for optimal fault tolerance and availability. This setup significantly reduces the risk of service disruption, ensuring a high level of reliability.

3. Ephemeral Node Strategy with SPOT Instances: In a move towards operational flexibility and cost efficiency, we've chosen to treat nodes as ephemeral. This approach enables us to utilize SPOT instances, which are more cost-effective than standard instances. While this might introduce some volatility in node availability, it aligns with our goal of optimizing costs.

4. Data Storage on RAID0 Array: We've opted for a RAID0 array for data storage, prioritizing performance. RAID0 arrays offer faster data access and can enhance overall system performance. However, we are aware that RAID0 does not offer redundancy. To mitigate this risk, we're implementing robust backup strategies and ensuring that critical data is replicated in secure and redundant storage systems.

5. Vault Auto-Unseal Feature: To accommodate the ephemeral nature of our nodes, we've configured Vault's auto-unseal feature. This ensures that if a node is replaced or rejoins the cluster, Vault will automatically unseal, minimizing downtime and manual intervention. This feature is crucial for maintaining seamless access to the Vault, especially in an environment where node volatility is expected.

In conclusion, our architecture for HashiCorp Vault is designed to strike a balance between performance, cost-efficiency, and resilience. While we embrace the dynamic nature of cloud resources for operational flexibility, we remain committed to ensuring data safety and system reliability through strategic architectural choices."

## 🔑 PKI

⚠️ All the certificates will be stored in the directory `.tls`
This directory is ignored by git in the `.gitignore` file
```
**/.tls/*
```

### 🔏 Generate Root/Intermediate certificates

<https://github.com/cloudflare/cfssl>

```json
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "ca": {
        "usages": ["signing", "key encipherment", "cert sign", "crl sign"],
        "expiry": "87600h",
        "ca_constraint": {
          "is_ca": true,
          "max_path_len": 0,
          "max_path_len_zero": true
        }
      }
    }
  }
}
```

```json
{
  "CN": "Ogenki Root CA",
  "key": {
    "algo": "ecdsa",
    "size": 256
  },
  "names": [{
    "C": "FR",
    "ST": "France",
    "L": "Paris",
    "O": "Ogenki"
  }]
}
```

```console
cfssl gencert -initca ca-csr.json | cfssljson -bare root-ca
2023/12/29 14:48:40 [INFO] generating a new CA key and certificate from CSR
2023/12/29 14:48:40 [INFO] generate received request
2023/12/29 14:48:40 [INFO] received CSR
2023/12/29 14:48:40 [INFO] generating key: ecdsa-256
2023/12/29 14:48:40 [INFO] encoded CSR
2023/12/29 14:48:40 [INFO] signed certificate with serial number 584367114912773617250168659463597813168080127593
```

```json
{
  "CN": "Ogenki Intermediate CA",
  "key": {
    "algo": "ecdsa",
    "size": 256
  },
  "names": [{
    "C": "FR",
    "ST": "France",
    "L": "Paris",
    "O": "Ogenki"
  }]
}
```

```console
cfssl gencert -initca intermediate-ca-csr.json | cfssljson -bare intermediate-ca
cfssl sign -ca root-ca.pem -ca-key root-ca-key.pem -config ca-config.json -profile ca intermediate-ca.csr | cfssljson -bare intermediate-ca
2023/12/29 14:56:08 [INFO] signed certificate with serial number 294435606185201236582907969087018601082935680805
```

For maximum security, your Root CA should be stored in an offline, air-gapped environment, such as a secure, physically isolated machine, an Hardware Security Module (HSM) or a securely stored USB device.

Generate Vault certificates from the intermediate CA:

```json
{
    "CN": "vault.priv.cloud.ogenki.io",
    "hosts": [
        "vault.priv.cloud.ogenki.io"
    ],
    "key": {
        "algo": "ecdsa",
        "size": 256
    },
    "names": [
        {
            "C": "FR",
            "ST": "France",
            "L": "Paris",
            "O": "KMTX"
        }
    ]
}
```

```console
cfssl gencert -ca intermediate-ca.pem -ca-key intermediate-ca-key.pem -config ca-config.json -profile=ca vault-csr.json | cfssljson -bare vault
```

```console
ls -1
ca-config.json
ca-csr.json
intermediate-ca-csr.json
intermediate-ca-key.pem
intermediate-ca.csr
intermediate-ca.pem
root-ca-key.pem
root-ca.csr
root-ca.pem
vault-csr.json
vault-key.pem
vault.csr
vault.pem
```


## 💾 Storage

