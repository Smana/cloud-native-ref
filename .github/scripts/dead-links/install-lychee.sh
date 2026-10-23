#!/usr/bin/env bash
# Installs lychee $LYCHEE_VERSION from its release, checked against $LYCHEE_SHA256, and puts it on
# PATH for the job's later steps. The workflow pins both: a digest, not a tag (merge gate MC5).
set -euo pipefail
d="$RUNNER_TEMP/lychee"
mkdir -p "$d"
curl -fsSL -o "$d/lychee.tgz" \
  "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-x86_64-unknown-linux-gnu.tar.gz"
echo "${LYCHEE_SHA256}  $d/lychee.tgz" | sha256sum -c -
tar -xzf "$d/lychee.tgz" -C "$d" --strip-components=1 lychee-x86_64-unknown-linux-gnu/lychee
echo "$d" >>"$GITHUB_PATH"
