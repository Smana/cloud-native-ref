# AI platform split — S4 (docs, site and CI moved) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended)
> or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** the AI docs (section, ADRs, runbooks, specs, plans, diagrams) live in `Smana/ai-native-ref`
with their history and publish on `airef.ogenki.io`; `cnref.ogenki.io` keeps one AI overview page and
an index row per moved ADR, and both sites link to each other.

**Conclusion first:** S4 is three PRs and two owner clicks. The ai-native-ref PR (history import,
site, CI, a deploy workflow that stays off) merges on green. The 👤 steps (a DNS record, the Pages
source, one repository variable) switch the deploy on. Only then does the cnref cleanup PR merge:
it removes published pages from the live site, so it waits for `airef.ogenki.io` to answer.

**Spec:** `docs/superpowers/specs/2026-10-12-ai-platform-split-design.md` §1 (docs rows), §5, §6 S4,
§8 defaults. **Follows:** S2 plan D4, S3 plan D4 (overlay). ADR-0057.
**Read at:** cnref `origin/main` `70a5d2c1`; ai-native-ref `main` `b316edd`.

| Fact | Value |
|---|---|
| `DOCS_FROM` | `70a5d2c157095b3ebc8b05731d7efd8ebcfdcd82` (the cnref sha filtered) |
| cnref site | Hugo `hugo-extended 0.168.0` (mise), Hextra `v0.12.3`; `docs.yml` deploys to GitHub Pages (`build_type: workflow`, custom domain `cnref.ogenki.io`, HTTPS enforced) |
| DNS | `cnref.ogenki.io CNAME smana.github.io.`; `ogenki.io` NS `dns{1,2}.registrar-servers.com` (Namecheap, owner's account) |
| ai-native-ref merges | `allow_merge_commit: false`, ruleset `main` requires linear history, no bypass |

---

## Decisions to confirm

| # | Decision | Recommended default | Why |
|---|---|---|---|
| D1 | URL layout on `airef.ogenki.io` | **Same paths** (`/docs/platform/ai-platform/…`, `/docs/decisions/00NN-…/`) | `filter-repo` keeps paths, so no relref changes inside the moved set and cnref's link-outs are a host swap |
| D2 | Which specs and plans move | **AI-only ones** (47); the split design and the S0–S4 plans **stay** | The split changes cnref and owns the host contract; ai-native-ref's `HOST-CONTRACT.md` is the copy |
| D3 | ADR-0057 | **Moves** (design §1), its cnref row links out | The decision record of the AI repository; ai-native-ref continues numbering from 0057 |
| D4 | Doc paths naming host files | ai-native-ref's `verify-doc-paths.sh` accepts a path present in its tree **or** in `.host/` (`HOST_REF`) | The moved pages name ~host paths (`opentofu/…`, `security/…`); `.host` is already checked out by CI |
| D5 | History import merge | **Merge commit** (`--allow-unrelated-histories`, D4 of S2) | Squash flattens the 113 commits. The repo forbids merge commits (linear-history ruleset): 👤 allow them for this one PR, or accept a linearised rebase (S4.2 step 5) |
| D6 | Deploy before DNS | **Off**: `docs.yml` runs only when the repo variable `PAGES_ENABLED == 'true'` | No deploy to a domain nobody configured |

---

## Move list (105 files, 113 commits)

| Group | Files | Path |
|---|---|---|
| AI section | 14 | `website/content/docs/platform/ai-platform/**` |
| AI ADRs | 17 | 0003, 0004, 0021, 0041–0046, 0048–0051, 0053, 0054, 0056, 0057 (0047, 0052, 0055 never merged) |
| Site diagrams | 10 | `website/static/images/diagrams/{ai-platform-1..5,llm-platform-1..3,agent-factory,agent-factory-overview}.svg` |
| drawio sources | 4 | `docs/architecture/{agent-factory,agent-factory-overview,ai-platform,llm-platform}.drawio` |
| Runbooks | 13 | `docs/runbooks/agent-factory/**` |
| Specs | 32 | `docs/superpowers/specs/*{llm,agent,ai-gateway,kagent,v2-}*` (incl. the cohort CSV) |
| Plans | 15 | `docs/superpowers/plans/*{llm,agent,ai-gateway,v2-}*` |

Stays: the split design and S0–S4 plans (D2), `gcp-parity` (platform), `image-gallery-v2` (App
wizard), the read-only `docs/specs/` archive, `docs/architecture/icons/`. History before a file was
renamed into its current path is dropped (most pages entered `website/` on 2026-08-20), as in S2.

Cross-references measured at `DOCS_FROM`:

| Direction | Count | Fix |
|---|---|---|
| Moved page `relref` → host page | 9 in 6 pages | Absolute `https://cnref.ogenki.io/…` (ai-native-ref PR) |
| Moved doc link → host file | 12 in 8 files | Absolute `https://github.com/Smana/cloud-native-ref/blob/main/…` |
| Host `relref` → moved page | 21 in 2 pages (`decisions/_index.md`, `gitops/_index.md`) | Absolute `https://airef.ogenki.io/…` (cleanup PR) |
| Host link → moved file | 18 in 7 files (`docs/architecture/README.md` 10, `cloud-support.md`, `gcp.md`, `clusters/AGENTS.md`, `clusters/CLAUDE.md`, split design 2) | Absolute URL to the AI site or ai-native-ref on GitHub |

---

### Task S4.1 🤖: this plan (cnref docs PR, merge on green)

### Task S4.2 🤖: history import (ai-native-ref)

- [ ] **Step 1:** fresh clone at `DOCS_FROM`: `git clone --single-branch --branch main --no-tags https://github.com/Smana/cloud-native-ref.git <tmp>` (no `reset`: filter-repo refuses a reflog with two entries).
- [ ] **Step 2:** `awk '{print "--path\n"$0}' files.txt > filter-args.txt` (the 105 files above) and `messages.txt` = `regex:\(#(\d+)\)==>(Smana/cloud-native-ref#\1)` (S2's).
- [ ] **Step 3:** `xargs -a filter-args.txt -d '\n' git filter-repo --replace-message messages.txt`
  Expected: `git ls-files | wc -l` → `105`, diff against `files.txt` empty, `git rev-list --count HEAD` → `113`.
- [ ] **Step 4:** `trufflehog git file://<tmp> --only-verified --fail` → `verified_secrets: 0`, rc 0.
- [ ] **Step 5:** in an ai-native-ref worktree: `git fetch <tmp> main:s4-docs-import && git merge --no-ff --allow-unrelated-histories s4-docs-import`.
  Merging the PR needs a merge commit (D5). Fallback if the owner declines: `git rebase --root`-style replay
  of the 113 commits onto `main` (`git rebase --onto origin/main --root s4-docs-import`, no conflicts:
  every path is new) and `gh pr merge --rebase`. Commits, authors and dates survive; parents do not.

### Task S4.3 🤖: the ai-native-ref site

| Path | Origin | Change |
|---|---|---|
| `website/{go.mod,go.sum,i18n,data,layouts,assets}` | copied once from cnref `DOCS_FROM` | `go.mod` module `github.com/Smana/ai-native-ref/website`; `data/{stack,repo-tree}.yaml` trimmed to AI |
| `website/assets/css/custom.css` | copied | `--primary-hue: 320deg` (both themes), nothing else |
| `website/static/{favicons,images/ogenki-mark*.svg,CNAME}` | copied | `CNAME` = `airef.ogenki.io` |
| `website/hugo.yaml` | copied | `baseURL: https://airef.ogenki.io/`, title "AI Native Reference", menu: AI platform, Decisions, **Cloud Native Ref ↗**, GitHub, Search; `editURL` to ai-native-ref; no constitution mount (links to cnref's page) |
| `website/content/{_index.md,docs/_index.md,docs/decisions/_index.md,docs/platform/_index.md}` | new | Home, the AI ADR index (17 rows, numbering continues at 0058), a platform stub pointing at the AI section |
| `website/content/docs/host-contract.md` | new | Links to `HOST-CONTRACT.md` and back to `cnref.ogenki.io` (a cross-site link) |
| Moved pages | imported | relrefs to host pages → absolute cnref URLs (9) |

- [ ] **Step 1:** `mise trust` the worktree (rc 1 "not trusted" looks like a site break), then
  `cd website && systemd-run --user --scope -q -p MemoryMax=6G hugo --gc --minify` → rc 0 with `refLinksErrorLevel: ERROR` on.

### Task S4.4 🤖: ai-native-ref CI

| Item | Change |
|---|---|
| `scripts/ci/validate-links.sh` | Already present; now also covers `docs/**` and `website/content/**` (Hugo-tree rule copied from cnref) |
| `scripts/ci/verify-doc-paths.sh` | cnref's, with D4: a path exists in this tree or under `.host/` |
| `taskfile.yaml` | `docs` task: `hugo --gc --minify` in `website/`, then `verify-doc-paths.sh`; `check` runs it |
| `.github/workflows/ci.yaml` | `docs` job: checkout, `HOST_REF` checkout into `.host`, mise, hugo module cache, `task docs`, `task links` |
| `.github/workflows/docs.yml` | cnref's deploy workflow, `if: vars.PAGES_ENABLED == 'true'` on the job (D6) |

- [ ] **Step 1:** local `task docs` and `task links` → rc 0; `actionlint` → clean.
- [ ] **Step 2:** PR, poll `gh pr view N --json statusCheckRollup` → all `SUCCESS`; merge (D5).

### Task S4.5 👤: hosting and DNS

- [ ] **Step 1 👤 DNS (Namecheap, `ogenki.io` Advanced DNS):** `CNAME  airef  smana.github.io.`, TTL automatic. Check: `dig +short airef.ogenki.io` → `smana.github.io.` then the four `185.199.10{8..11}.153`.
- [ ] **Step 2 👤 Pages source:** `gh api -X POST repos/Smana/ai-native-ref/pages -f build_type=workflow` (or Settings → Pages → Source: GitHub Actions); then `gh api -X PUT repos/Smana/ai-native-ref/pages -f cname=airef.ogenki.io`.
- [ ] **Step 3 👤 switch on:** `gh variable set PAGES_ENABLED --repo Smana/ai-native-ref --body true`, then `gh workflow run docs.yml --repo Smana/ai-native-ref`.
- [ ] **Step 4 👤 HTTPS:** once the certificate is issued (minutes to an hour): `gh api -X PUT repos/Smana/ai-native-ref/pages -F https_enforced=true`.
  Check: `curl -sI https://airef.ogenki.io/ | head -1` → `HTTP/2 200`.

No token is needed: Pages deploys with the workflow's `id-token` and `pages: write`.

### Task S4.6 🤖: the cnref cleanup PR (opened in parallel, merged after S4.5)

| Where | Change |
|---|---|
| `website/content/docs/platform/ai-platform/` | 13 pages removed; `_index.md` rewritten: what the AI platform is, the four `flux resume` commands, links out |
| 17 AI ADRs | Removed; `decisions/_index.md` keeps each row, linked to `https://airef.ogenki.io/docs/decisions/<slug>/` |
| `docs/platform/_index.md`, `gitops/_index.md` | Cards and relrefs into moved pages → absolute URLs |
| `hugo.yaml` menu | "AI platform ↗" beside GitHub |
| 10 SVGs, 4 drawio, runbooks, 47 specs and plans | Removed; host links to them → ai-native-ref URLs |
| `.doc-claims.yaml` | AI entries whose page moved are dropped (ai-native-ref owns them later) |
| `docs-check.yml` overlay step | **Kept only if** host pages still backtick AI manifest paths after the move (`verify-doc-paths.sh` without the overlay tells); the manifest overlay in `ci.yaml` stays (render) |

- [ ] **Step 1:** `hugo --gc --minify` rc 0, `validate-links.sh` rc 0, `verify-doc-paths.sh` rc 0 (after `task ai:overlay`).
- [ ] **Step 2:** PR body opens with **DO NOT MERGE until airef.ogenki.io serves and the cross-site links answer 200**; CI green; 👤 merges after S4.7.

### Task S4.7 🤖: cross-site link check — the S4 gate

```bash
# every absolute link from one site to the other, from both built trees
grep -rhoE 'https://(airef|cnref)\.ogenki\.io/[^")# ]*' <cnref>/website/content <anr>/website/content \
  <cnref>/website/hugo.yaml <anr>/website/hugo.yaml | sort -u > xlinks.txt
while read -r u; do printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -L "$u")" "$u"; done < xlinks.txt | grep -v '^200 '
```

Expected: no output (every link 200). Run after S4.5 (airef live) for cnref → airef links, and
after the cleanup PR merges and `docs.yml` deploys for airef → cnref links into the overview page.

| Gate | Both repositories |
|---|---|
| `hugo --gc --minify` | rc 0 |
| `validate-links.sh` | rc 0 |
| `verify-doc-paths.sh` | rc 0 |
| Cross-site links | every one `200` |

---

## Rollback

| Stage | Undo |
|---|---|
| ai-native-ref PR merged, site off | Nothing live; `git revert -m 1 <merge>` removes the import |
| airef live, cleanup not merged | cnref still serves the full AI section: unset `PAGES_ENABLED`, delete the DNS record |
| Cleanup merged | `git revert` the cleanup PR; `docs.yml` republishes the AI pages on cnref within one run |

## Risks

| Risk | Mitigation |
|---|---|
| cnref pages removed before airef serves | Cleanup PR is DO NOT MERGE until S4.7's first half passes |
| Cross-site links rot (no relref across sites) | Few, all absolute; S4.7 lists them from source, not by hand |
| Moved pages name host paths that later move | ai-native-ref's `verify-doc-paths.sh` checks them against `HOST_REF`; each Renovate bump re-checks |
| Docs edited on cnref between `DOCS_FROM` and the cleanup merge | `git log DOCS_FROM..origin/main -- <105 paths>` before merge; port with S2.7 step 4's recipe |
| The two themes drift | Copied once; a shared module only if they diverge (design §7) |
