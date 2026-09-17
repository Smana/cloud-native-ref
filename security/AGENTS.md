# Security — OpenBao, PKI, IAM, network policy

## CiliumNetworkPolicy authoring

The constitution mandates default-deny plus explicit allow on every pod-running workload. Four
traps surfaced repeatedly during the LLM-platform first deploy. Fix them at write time, not via
Hubble afterwards.

1. **DNS L7 inspection is mandatory for any `toFQDNs` rule to work.** The kube-dns egress rule must
   include `toPorts.rules.dns.matchPattern: "*"`. Without it Cilium proxies the query but never
   sees the response IPs, so the `toFQDNs` allowlist has no IPs to match and every TCP follow-up is
   silently `Policy denied DROPPED`. DNS keeps working; downstream connections fail.

2. **`matchPattern: "*"` does not span dots.** `*.huggingface.co` matches `cdn.huggingface.co` but
   not `cas-bridge.xet.huggingface.co`. CDN topology fans out fast, so `toFQDNs` becomes a
   maintenance chase. Check what Cilium thinks a dropped IP resolved to:
   `kubectl exec -n kube-system <cilium-agent-on-that-node> -- cilium fqdn cache list -o json`.

3. **`toEntities: world` excludes link-local, and `toCIDR` alone does not match host-network
   endpoints.** The EKS Pod Identity Agent at `169.254.170.23:80` runs on the node's host network,
   so Cilium classifies the destination as the `host` entity and `toCIDR: 169.254.170.23/32`
   silently fails. Use `toEntities: ["host"]` scoped to TCP 80. Symptom: `Connect timeout on
   endpoint URL: 'http://169.254.170.23/v1/credentials'` from the AWS SDK.

4. **Escaping to `toEntities: world` on TCP 443** is acceptable only for a bounded one-shot job
   (preload/build/init with a TTL) under restricted PSS with scoped IAM and HTTPS-only egress.
   Never on a long-lived serving pod — render two policies, one per workload selector, instead of
   widening the runtime pod's egress.

Diagnostic order when egress looks broken:
`hubble observe --pod <ns>/<pod> --verdict DROPPED --last 50` → reverse-IP via `cilium fqdn cache
list -o json` on that node's agent → check `rules.dns` on the kube-dns rule → check matchPattern
subdomain depth → check link-local.

## OpenBao

```bash
export VAULT_ADDR=https://bao.priv.aws.ogenki.io:8200
export VAULT_CACERT=../opentofu/aws/openbao/management/.tls/ca.pem   # prefer this over VAULT_SKIP_VERIFY
bao status
bao login -method=userpass username=admin

aws secretsmanager get-secret-value \
  --secret-id openbao/cloud-native-ref/users/admin \
  --query SecretString --output text | jq
```

The operator login is userpass in the **root** namespace, managed by
`../opentofu/aws/openbao/management/auth.tf`, carrying both the admin and pki-admin policies.

**Namespace layout.** Shared platform services live in the **root** namespace: the PKI
(`pki_private_issuer`), the per-cluster JWT auth mounts, the `oidc/` mount and its identity groups,
operator logins, and the two kv-v2 mounts `platform/` and `apps/`. The mounts are in root because a
policy binds only within its own namespace, so a mount in a child namespace is unreachable by a
policy on a root identity group (ADR-0036). **There is no tenant namespace** — the `app` one was
removed for exactly that reason, and `namespaces.tf` no longer exists on either cloud. Cluster-wide
endpoints such as `sys/storage/raft/*` are callable only from root.

**Secret grants.** `secrets-admin` covers both mounts and must be attached to the `userpass`
break-glass login *as well as* the `openbao-admin` OIDC group — the OIDC route depends on ZITADEL,
whose own credential lives in `platform/zitadel/envvars`. Adding a mount means adding it to
`auth.tf`'s policy list in the same change. External Secrets is **read-only** on both mounts by
design.

Storage is rebuilt from its newest snapshot on every deploy (the *lineage*, ADR-0033). The lineage
and management stacks survive the default `destroy`; `TM_LINEAGE_DESTROY=true` overrides. Machine
auth is the JWT method on `jwt/<cluster>`, and consumers reach it at
`openbao.security.svc.cluster.local:8200`.

**`bao status` hanging means a core deadlock, never the VPN.** OpenBao 2.6's namespace deadlock is
our own write concurrency — fixed with `-parallelism=1`, not by pinning a version.

## PKI

Offline root CA → intermediate CA → leaf certificates. The root signed each cloud's intermediate
offline, once; only the intermediate's cert+key bundle is imported into the `pki` mount, and that
intermediate **is** the issuer. OpenBao never holds the root key — the `root-ca` Secrets Manager
entry that used to carry it is deleted. One root for both clouds, so a tailnet client trusts one
anchor. See `../opentofu/aws/openbao/management/pki.tf`.

cert-manager authenticates with a **projected ServiceAccount token** against the per-cluster JWT
mount (`jwt/<cluster>`, role `cert-manager`) — not an AppRole, and no long-lived credential
anywhere. It needs `create` on `serviceaccounts/token` for itself to mint that token:
`base/cert-manager-token-creator/rbac.yaml`.

**OpenBao serves a leaf-only certificate**, so importing the root CA in a browser can never be
enough on its own.

## IAM

- **EKS Pod Identity, never IRSA** (ADR-0002). Injection happens at admission, so a pod that
  started before the association existed needs deleting, not restarting.
- Crossplane controllers are scoped to `xplane-*` resources.
- **No deletion permissions** for stateful services — S3, IAM, Route53.
- EPI definitions live in `base/epis/`.

## Network

Private EKS API endpoint, Tailscale VPN for private resources, Cilium policies for pod-to-pod,
Gateway API for ingress with TLS termination. The two Tailscale gateways and their ACL split are
documented in `../infrastructure/AGENTS.md`.
