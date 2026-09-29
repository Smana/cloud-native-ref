#!/usr/bin/env bash
#
# Every policy a cluster's OpenBao JWT roles name must be DEFINED by that cloud's
# OpenBao management stack -- directly, or through a module it calls.
#
# WHY THIS EXISTS
#
# A JWT role references its policies BY NAME, from a different state: the roles
# live in opentofu/<cloud>/<k8s>/configure/openbao.tf, the policies in
# opentofu/<cloud>/openbao/management. OpenBao accepts a role naming a policy
# that does not exist, and the login succeeds -- it just grants nothing. When
# Stage 2 shipped (2026-09-10), jwt/gcp-0's external-secrets role named
# `external-secrets`, which only the AWS management stack defined, so all 14
# OpenBao-backed ExternalSecrets on gcp-0 authenticated and read nothing. CI
# rendered every manifest and stayed green; nothing tied the two states.
#
# This reads committed HCL, not a live OpenBao, so it answers "would this
# configuration leave a role pointing at nothing?", not "does it right now?".
# Templated policy names (app-${each.value}) are not literal names and never
# satisfy a role; the built-in `default` policy is never required.
#
# SCOPE EDGES (none reachable today, but honest): roles are read only from
# opentofu/<cloud>/*/configure/openbao.tf, so a role moved to a sibling file
# goes unchecked; a `vault_policy` gated to `count = 0` still counts as
# defined; and a policy name built from a variable, not a literal string, is
# not resolved either way.
#
# Usage: validate-openbao-policies.sh [ROOT_DIR]
set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel)}"

exec python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
QUOTED = re.compile(r'"([^"$]+)"')
fails = []

def referenced(path):
    names = set()
    for m in re.finditer(r'policies\s*=\s*\[([^\]]*)\]', path.read_text()):
        names.update(QUOTED.findall(m.group(1)))
    names.discard("default")
    return names

def literal_policy_names(directory):
    names = set()
    for tf in sorted(directory.glob("*.tf")):
        for block in re.finditer(r'resource\s+"vault_policy"\s+"[^"]+"\s*\{(.*?)\n\}', tf.read_text(), re.S):
            n = re.search(r'^\s*name\s*=\s*"([^"$]+)"\s*$', block.group(1), re.M)
            if n:
                names.add(n.group(1))
    return names

def called_module_dirs(directory):
    dirs = []
    for tf in sorted(directory.glob("*.tf")):
        for block in re.finditer(r'module\s+"[^"]+"\s*\{(.*?)\n\}', tf.read_text(), re.S):
            s = re.search(r'^\s*source\s*=\s*"(\.[^"]+)"', block.group(1), re.M)
            if s:
                dirs.append((directory / s.group(1)).resolve())
    return dirs

opentofu = root / "opentofu"
clouds = sorted(p.name for p in opentofu.iterdir() if p.is_dir() and p.name != "shared") if opentofu.is_dir() else []
checked = 0
for cloud in clouds:
    configs = sorted((opentofu / cloud).glob("*/configure/openbao.tf"))
    if not configs:
        continue
    mgmt = opentofu / cloud / "openbao" / "management"
    if not mgmt.is_dir():
        fails.append(f"{cloud}: {configs[0].relative_to(root)} names OpenBao policies, but there is no opentofu/{cloud}/openbao/management")
        continue
    wanted = set().union(*(referenced(c) for c in configs))
    defined = literal_policy_names(mgmt)
    for d in called_module_dirs(mgmt):
        if d.is_dir():
            defined |= literal_policy_names(d)
    checked += 1
    for name in sorted(wanted - defined):
        fails.append(f'{cloud}: a JWT role names policy "{name}", but opentofu/{cloud}/openbao/management does not define it (directly or through a module it calls)')

if checked == 0 and not fails:
    fails.append("no opentofu/<cloud>/*/configure/openbao.tf found -- nothing to check, which is itself wrong")

for f in fails:
    print(f"FAIL: {f}")
if fails:
    print(f"==> OpenBao policy parity: {len(fails)} problem(s). A role naming an undefined policy logs in and reads nothing.")
    sys.exit(1)
print(f"==> OpenBao policy parity: every policy a JWT role names is defined ({checked} cloud(s)).")
PY
