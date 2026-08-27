#!/usr/bin/env bash
# Formats and mounts the OpenBao data disk. Rendered into the instance's
# `metadata_startup_script` (compute.tf), concatenated BEFORE startup-script.sh
# -- the data disk has to be mounted before OpenBao is configured to write its
# storage there. Runs on every boot, not only the first: the idempotency
# checks below (skip mkfs if a filesystem already exists, `systemctl enable
# --now` is itself idempotent) are what make that safe.
#
# THIS SCRIPT AND startup-script.sh ARE JOINED INTO ONE metadata_startup_script
# AND SHARE ONE PROCESS (compute.tf: `join("\n", [templatefile(setup-local-
# disks.sh, ...), templatefile(startup-script.sh, ...)])`). `set -o errexit`
# and any bare `exit` in either half therefore terminates the WHOLE combined
# script, not just its own half -- an `exit 0` here silently skips OpenBao's
# install/configure/start in startup-script.sh entirely: the instance boots,
# joins the MIG, reports RUNNING, and serves nothing. That is why the
# missing-disk branch below is `exit 1`, not `exit 0` -- unlike AWS, where the
# instance-store disk is genuinely optional scratch space, this stack's data
# disk is declared by compute.tf and always attached; its absence is a
# provisioning bug, a hard error, never a state to boot past quietly.
#
# Ported from
# opentofu/aws/openbao/cluster/scripts/setup-local-disks.sh, which discovers
# and RAID-0s ephemeral NVMe instance store via a udev alias glob, because AWS
# gives no stable, predictable device path for instance-store disks. GCP does:
# a persistent disk attached with a fixed `device_name` (compute.tf sets
# device_name = "openbao-data") always appears at
# /dev/disk/by-id/google-<device_name>. That removes the whole discovery/RAID
# step -- there is exactly one disk, at a known path, every boot.

set -o errexit
set -o pipefail
set -o nounset

err_report() {
  echo "Error occurred on line $1: $BASH_COMMAND"
}
trap 'err_report $LINENO' ERR

check_command() {
  local cmd=$1
  if ! command -v "$cmd" &> /dev/null; then
    echo "Command not found: $cmd"
    exit 1
  fi
}

# xfsprogs (mkfs.xfs) is NOT on the stock Ubuntu image and must be installed
# here, before it is needed -- this script runs BEFORE startup-script.sh
# (compute.tf concatenation order), so an `apt-get install` living only in the
# latter half is too late for mkfs.xfs below. systemd-analyze/blkid/lsblk come
# from systemd/util-linux, both base-image packages, so no install is needed
# for them.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq xfsprogs

check_command mkfs.xfs
check_command systemd-analyze
check_command blkid
check_command lsblk

DATA_DISK="/dev/disk/by-id/google-openbao-data"
MNT_DIR="${openbao_data_path}"

if [[ ! -e "$DATA_DISK" ]]; then
  # Hard error, not a skip -- see the file-header note. compute.tf always
  # attaches this disk; if it is missing, something about the instance
  # template or the disk attachment is broken, and continuing would boot
  # OpenBao onto whatever the root filesystem happens to have at
  # openbao_data_path instead of failing loudly.
  echo "Data disk $DATA_DISK not found -- this is a hard failure, not optional scratch space (unlike AWS's ephemeral NVMe)"
  exit 1
fi

if [[ $(id --user) -ne 0 ]]; then
  echo "Must be run as root"
  exit 1
fi

# Idempotent: only format a disk that has no filesystem yet. A re-run after
# the unit is already mounted must not reformat a disk holding OpenBao's raft
# or file storage.
if [[ -z $(lsblk "$DATA_DISK" -o fstype --noheadings) ]]; then
  mkfs.xfs "$DATA_DISK"
fi

mkdir -p "$MNT_DIR"

DEV_UUID=$(blkid -s UUID -o value "$DATA_DISK")
UNIT_NAME="$(systemd-escape --path --suffix=mount "$MNT_DIR")"

cat > "/etc/systemd/system/$UNIT_NAME" << EOF
[Unit]
Description=Mount OpenBao data disk at $MNT_DIR

[Mount]
What=UUID=$DEV_UUID
Where=$MNT_DIR
Type=xfs
Options=defaults,noatime

[Install]
WantedBy=multi-user.target
EOF

systemd-analyze verify "$UNIT_NAME"
systemctl enable "$UNIT_NAME" --now

echo "Successfully mounted $DATA_DISK at $MNT_DIR"
