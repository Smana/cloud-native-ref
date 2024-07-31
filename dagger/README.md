# Bootstrap workflow

This Dagger workflow allows to easy the bootstrap process. There are indeed several steps and a few command to run in order to have the whole platform up and running.

```mermaid
graph TD
    A[Create AWS Network and Tailscale Subnet Router Terraform]

    A --> B[Deploy and Configure Vault]

    B --> B1[Create Cluster and Wait for Vault]
    B1 --> B2[Connect to Vault and Run Init]
    B2 --> B3[Run PKI Configuration]
    B3 --> B4[Apply Vault Management]
    B4 --> B5[Retrieve Cert-Manager AppRole]
    B5 --> C[Update Vault AppRole in Cert-Manager Configuration]

    C --> D[Deploy EKS Cluster]

```

```console
dagger call clean --source="." -v
```


```console
 dagger call bootstrap --source "." --access-key-id=env:AWS_ACCESS_KEY_ID --secret-access-key=env:AWS_SECRET_ACCESS_KEY -v
 ```
