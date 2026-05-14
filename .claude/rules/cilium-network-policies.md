---
description: CiliumNetworkPolicy authoring traps — DNS L7, FQDN match, link-local, escape-hatch
globs:
  - "**/*ciliumnetworkpolicy*.yaml"
  - "infrastructure/base/**/*network-policy*.yaml"
  - "apps/base/**/*network-policy*.yaml"
  - "tooling/base/**/*network-policy*.yaml"
  - "security/base/**/*network-policy*.yaml"
  - "infrastructure/base/crossplane/configuration/kcl/**/*.k"
---

# CiliumNetworkPolicy Rules

Constitution mandates default-deny + explicit allow on every pod-running workload. Four traps surfaced repeatedly during the LLM-platform first-deploy session — fix at write time, not via Hubble after the fact.

1. **DNS L7 inspection is mandatory for any `toFQDNs` rule to work.** The kube-dns egress rule MUST include `toPorts.rules.dns.matchPattern: "*"`. Without it Cilium proxies the DNS query but never sees the response IPs, so the `toFQDNs` allowlist has no IPs to match — every TCP follow-up is silently `Policy denied DROPPED`. DNS keeps working, downstream connections silently fail.
2. **`matchPattern: "*"` does NOT span dots** (single-segment glob). `*.huggingface.co` matches `cdn.huggingface.co` but NOT `cas-bridge.xet.huggingface.co`. CDN topology fans out fast; `toFQDNs` becomes a maintenance chase. Verify with `kubectl exec -n kube-system <cilium-agent-on-pod-node> -- cilium fqdn cache list -o json` to see what Cilium thinks each dropped IP resolved to.
3. **`toEntities: world` does NOT include link-local addresses, AND `toCIDR` alone does NOT match host-network endpoints.** EKS Pod Identity Agent at `169.254.170.23:80` runs on the node's host network — Cilium classifies the destination as the `host` entity, so `toCIDR: 169.254.170.23/32` silently fails (Hubble: `policy-verdict:none ... DENIED`). Use `toEntities: ["host"]` scoped to TCP 80 instead; combine with toCIDR if you want both audit clarity and a working policy. Symptom: `Connect timeout on endpoint URL: 'http://169.254.170.23/v1/credentials'` from the AWS SDK.
4. **When to escape from `toFQDNs` to `toEntities: world` on TCP 443.** Acceptable only when the pod is bounded one-shot (preload/build/init Job with a TTL), restricted PSS already enforced, scoped IAM, and the egress is HTTPS-only. Default-deny on every other port still applies. Don't use this on long-lived serving pods — render two CiliumNetworkPolicies (one per workload selector) instead of widening the runtime pod's egress.

Diagnostic order when egress looks broken: `hubble observe --pod <ns>/<pod> --verdict DROPPED --last 50` → reverse-IP via `cilium fqdn cache list -o json` on the right node's cilium agent → check `rules.dns` on the kube-dns rule → check matchPattern subdomain depth → check link-local.
