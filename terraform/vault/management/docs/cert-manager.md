## ☸ Use it with cert-manager


```console
systemctl status docker.service
```

Cert-manager allows to provision certificates within a Kubernetes cluster. In order to test it, we'll create a local k8s cluster in our laptop.

```console
echo "nameserver 100.100.100.100" > /tmp/resolv.conf
```

```yaml
apiVersion: k3d.io/v1alpha4
kind: Simple
kubelet:
  extraArgs:
    resolv-conf: /tmp/resolv.conf
```

Create by running this command:
```console
k3d cluster create cert-manager --config k3d-config.yaml
```

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

```console
CERT_MANAGER_ROLE_ID=$(vault read --field=role_id auth/approle/role/cert-manager/role-id)
CERT_MANAGER_SECRET_ID=$(vault write --field=secret_id -f auth/approle/role/cert-manager/secret-id)
VAULT_DDR=https//vault.priv.cloud.ogenki.io
CA_CHAIN_B64=$(base64 -w0 .tls/ca-chain.pem)
```


```console
kubectl create secret generic cert-manager-vault-approle --from-literal=secretId="${CERT_MANAGER_SECRET_ID}" -n security
```

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

Create a test certificate:
```yaml
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
```