# 09 — App key compromise

What to do when the private key of any GitHub App the platform holds — the agents' App, the
factory's App, the merger's App or the merge gate's policy-bot — is suspected stolen. The table
names, per App, where the key lives in OpenBao, which ExternalSecret holds it, and what a stolen
key can do. The procedure, for any row, is the same five steps. See [README.md](README.md) for
prerequisites.

| App | Key at | Held by (ExternalSecret, namespace) | A stolen key can |
|---|---|---|---|
| `ogenki-agents` | `agents/github-app` | octo-sts (`octo-sts-github-app`, `agent-system`) | push `agent/**`, open and comment on PRs |
| `ogenki-agent-factory` | `agents/factory-app` | the factory (`agent-factory-github`) and the broker (SP2 P31), `agent-system` | comment, label and edit issues and PRs |
| `ogenki-agent-merger` | `agents/merger-app` | the factory only (`agent-factory-merger`, `agent-system`) | after Task 10.7, merge any PR with 8 green checks and `policy-bot: main` `success`, and push `revert-*` and `agent/**` (R16); before it, push `agent/**` only |
| `ogenki-merge-gate` | `merge-gate/policy-bot` | policy-bot (`policy-bot`, `merge-gate`) | post `policy-bot: main` `success` on any PR, so the gate stops meaning anything once `agent-merge-gate` is applied |

## Procedure, for any row

1. **Stop.** Suspend the installation (`https://github.com/settings/installations` → the App →
   Suspend): every installation token fails at once. For the agents' App this is also the kill
   switch's GitHub layer (Task 8.4 Step 5).
2. **Rotate.** In the App's settings, generate a new private key, then
   `bao kv patch -mount=<mount> <key> private_key=@<new>.pem && shred -u <new>.pem`, with the table's
   `<mount>/<key>` (`patch` keeps policy-bot's other fields).
3. **Reload.** `kubectl annotate externalsecret <name> -n <namespace> force-sync="$(date +%s)" --overwrite`,
   then `kubectl rollout restart deployment/<holder> -n <namespace>` for each holder.
4. **Revoke.** Delete the leaked key in the App's settings (match its SHA-256 fingerprint).
5. **Resume and audit.** Unsuspend. For the merger or the merge gate, list what merged since the
   leak: `gh pr list --state merged --search "merged:>=<leak date>" --json number,mergedBy,mergedAt`;
   revert anything its key merged that a human did not intend.
