## ☸ Use it with cert-manager

Integrate `cert-manager` with Vault for robust certificate management in Kubernetes. Follow these steps for a smooth setup.

## ✅ Requirements

Before integrating `cert-manager` with Vault, ensure these prerequisites are met:

- **Vault Setup**: A Vault instance with permissions to manage [approles](https://developer.hashicorp.com/vault/docs/auth/approle). Use our guide for [building a Vault cluster](https://github.com/Smana/demo-cloud-native-ref/blob/main/terraform/vault/cluster/README.md).
- **TLS Configuration**: Ensure a proper TLS setup, including the CA chain. If you've followed the [PKI requirements procedure](https://github.com/Smana/demo-cloud-native-ref/blob/refactor_docs_per_topic/terraform/vault/cluster/docs/pki_requirements.md), you should have `.tls/ca-chain.pem` locally.
- **Kubernetes Cluster**: A Kubernetes cluster capable of reaching the Vault. You can set one up using our [EKS cluster guide](https://github.com/Smana/demo-cloud-native-ref/blob/main/terraform/eks/README.md).

Once these requirements are met, you're ready to proceed with the `cert-manager` integration.

## Install cert-manager

ℹ️ **Note**: If you've used the code from this repository to set up the EKS cluster, `cert-manager` should already be operational, deployed via GitOps with Flux. In this case, you can skip the installation step.

Add the Helm repository:
```console
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

Deploy cert-manager:
```console
helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.13.3 \
  --set installCRDs=true
```

Check that the pods are actually running
```console
kubectl get po -n cert-manager
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-8db45d64b-hmfgt               1/1     Running   0          38s
cert-manager-cainjector-5c8d6f6646-tbqj5   1/1     Running   0          38s
cert-manager-webhook-7c7d969c76-kds7h      1/1     Running   0          38s
```

## Create the Vault cluster issuer

In the context of cert-manager, a `ClusterIssuer` is a Kubernetes resource used to issue SSL/TLS certificates. It operates at the cluster level, meaning it can provide certificates for any namespace within the cluster. This is distinct from an Issuer, which functions at a namespace level and can only issue certificates within its own namespace. ClusterIssuers are typically used for centralized certificate management across multiple namespaces.

As stated in the requirements, Vault should be reachable from the Kubernetes cluster but also from the CLI in order to run the following commands that make use of the `vault` CLI.

⚠️ During this procedure we'll use the `root` token but this is strongly recommended to configure an Identity provider as soon as the cluster is up and running. More about that [here](root_token.md).

1. Check that you can effectively access to Vault.
   ```console
   export VAULT_SKIP_VERIFY=true
   export VAULT_TOKEN=<token>
   export VAULT_ADDR="https://vault.priv.cloud.ogenki.io"
   vault secrets list
   ```

   This command should output something like
   ```console
    Path                   Type         Accessor              Description
    ----                   ----         --------              -----------
    cubbyhole/             cubbyhole    cubbyhole_7e5150cd    per-token private secret storage
    identity/              identity     identity_900b3c87     identity store
    pki/                   pki          pki_0b833e86          n/a
    pki_private_issuer/    pki          pki_23f1dc2d          Ogenki Vault Issuer
    sys/                   system       system_8f1e8dc2       system endpoints used for control, policy and debugging
   ```

2. Build the variables needed to create the `ClusterIssuer`
   Check that the `cert-manager` approle is already created. You can list the available approles:
   ```console
   vault list auth/approle/role
   ```

   Retrieve the `role_id` and `secret_id`
   ```console
   CERT_MANAGER_ROLE_ID=$(vault read --field=role_id auth/approle/role/cert-manager/role-id)
   CERT_MANAGER_SECRET_ID=$(vault write --field=secret_id -f auth/approle/role/cert-manager/secret-id)
   ```

   Create the variables specific to your Vault instance.
   ```console
   VAULT_DDR=https//vault.priv.cloud.ogenki.io
   CA_CHAIN_B64=$(base64 -w0 .tls/ca-chain.pem)
   ```

3. Create the `vault` ClusterIssuer
   The secret_id should be stored in a secret as follows. (In this example cert-manager has been installed in the `security` namespace)
   ```console
   kubectl create secret generic cert-manager-vault-approle --from-literal=secretId="${CERT_MANAGER_SECRET_ID}" -n security
   ```

   Create the CR
   ```console
   kubectl apply -f - <<EOF
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: vault
     namespace: security
   spec:
     vault:
       server: ${VAULT_ADDR}
       path: pki_private_issuer/sign/pki_private_issuer
       caBundle: ${CA_CHAIN_B64}
       auth:
         appRole:
           path: approle
           roleId: ${CERT_MANAGER_ROLE_ID}
           secretRef:
             name: cert-manager-vault-approle
             key: secretId
   EOF
   ```

   Check that the vault ClusterIssuer has been properly initialized
   ```console
   kubectl describe clusterissuers.cert-manager.io vault | grep -A 10 ^Status:
   ```
   It should be `Ready` with the reason `VaultVerified`
   ```console
   Status:
   Conditions:
     Last Transition Time:  2024-01-11T08:00:41Z
     Message:               Vault verified
     Observed Generation:   1
     Reason:                VaultVerified
     Status:                True
     Type:                  Ready
   Events:                    <none>
   ```

## Create your first certificate

1. Create a test certificate:
   ```console
   kubectl apply -f - <<EOF
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: foobar
   spec:
     secretName: foobar-tls
     duration: 2160h # 90d
     renewBefore: 360h # 15d
     commonName: foobar.priv.cloud.ogenki.io
     dnsNames:
       - foobar.priv.cloud.ogenki.io
       - foobar.security.svc.cluster.local
     issuerRef:
       name: vault
       kind: ClusterIssuer
       group: cert-manager.io
   EOF
   ```

2. Check that it has been properly provision
   ```console
   kubectl describe cert foobar | grep -A 20 ^Status:
   Status:
     Conditions:
       Last Transition Time:  2024-01-11T08:05:05Z
       Message:               Certificate is up to date and has not expired
       Observed Generation:   1
       Reason:                Ready
       Status:                True
       Type:                  Ready
     Not After:               2024-04-10T08:05:05Z
     Not Before:              2024-01-11T08:04:35Z
     Renewal Time:            2024-03-26T08:05:05Z
     Revision:                1
   Events:
     Type    Reason     Age   From                                       Message
     ----    ------     ----  ----                                       -------
     Normal  Issuing    57s   cert-manager-certificates-trigger          Issuing certificate as Secret does not exist
     Normal  Generated  57s   cert-manager-certificates-key-manager      Stored new private key in temporary Secret resource "foobar-bt2rp"
     Normal  Requested  57s   cert-manager-certificates-request-manager  Created new CertificateRequest resource "foobar-1"
     Normal  Issuing    57s   cert-manager-certificates-issuing          The certificate has been successfully issued
   ```

   You can also check the certificate contents
   ```console
   kubectl get secrets foobar-tls -o jsonpath="{.data.tls\.crt}" | base64 -d | openssl x509 -noout -text
   Warning: Reading certificate from stdin since no -in or -new option is given
   Certificate:
       Data:
           Version: 3 (0x2)
           Serial Number:
               3d:2f:99:5d:ab:81:37:a6:ae:cd:27:d6:bb:31:3a:ca:4a:31:70:f2
           Signature Algorithm: ecdsa-with-SHA256
           Issuer: O=Ogenki, CN=Ogenki Vault Issuer
           Validity
               Not Before: Jan 11 08:04:35 2024 GMT
               Not After : Apr 10 08:05:05 2024 GMT
           Subject: C=France, O=Ogenki, CN=foobar.priv.cloud.ogenki.io
   ...
               X509v3 Subject Alternative Name:
                   DNS:foobar.priv.cloud.ogenki.io, DNS:foobar.security.svc.cluster.local
   ...
   ```